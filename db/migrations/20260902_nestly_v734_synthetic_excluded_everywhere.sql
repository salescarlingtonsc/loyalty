-- NESTLY v734 — synthetic-client exclusion, estate sweep: the CI-100 checklist's checks 1
-- (canonical transaction population), 3 (identified vs anonymous revenue reconciles exactly)
-- and 10 (golden reconciliation) all require ONE population definition for "which sales count
-- as this business's revenue/visits", and nestly_v687 already named the authority
-- (app.analytics_sale_class_v1.is_synthetic_client, nestly_v628) — but v687 only reached
-- public.get_revenue_truth_v106 and the v6xx Customer Intelligence readers built after v628.
-- db/tests/executed/v731_reconciliation_report.sql proved the gap directly: A (v106) reconciles
-- to 100.0%, B/C/D (dashboard, AI evidence pack, platform consultant report) do not, because a
-- synthetic client's real sales still count as revenue and visits there.
--
-- ESTATE SCAN (this migration's own homework, not asserted by fixture — the fixture below only
-- proves the functions actually touched). Every function in public+app whose live
-- pg_get_functiondef body reads `from public.sales` and mentions revenue or visit(s):
--
--   ALREADY CORRECT (verified, not touched):
--     * Every get_ci_*_v1 / app.ci_*_v1 reader (app.analytics_sale_class_v1 or an equivalent
--       is_synthetic filter already gates the population — v628/v680/v683 lineage).
--     * public.get_revenue_truth_v106 — fixed by nestly_v687.
--     * app.v177_customers — real_clients CTE already filters is_synthetic=false.
--     * app.v666_till_customer_card — reads ONE named client's own visits (the till operator
--       looked this client up directly); there is no "which population" ambiguity to exclude.
--     * public.get_attention_list_v548 — the `judged` CTE already joins clients and filters
--       `coalesce(c.is_synthetic,false)=false` before any count (comment on that CTE says so
--       explicitly: "the synthetic exclusion also governs the 'considered' count").
--     * public.get_recovery_report_v550 — `raw_visits`/`visits` are unfiltered, but every reader
--       of those CTEs (`interventions`, `baseline_cohort`, `redeemed`) joins `real_clients`
--       (coalesce(c.is_synthetic,false)=false) before summing window_cents/gross_cents, so no
--       synthetic client's sale can reach a reported figure — the unfiltered CTE never leaks.
--     * app.customer_cadence_batch_v1 (nestly_v651) — returns per-client interval rows, not a
--       business-wide revenue/visit total; its callers (app.ci_customer_classes_v1 et al.) are
--       independently verified above to exclude synthetic clients before using cadence figures.
--
--   FIXED HERE (did not exclude; each got exactly the v687-style
--   `cross join lateral app.analytics_sale_class_v1(<alias>) sc ... and not sc.is_synthetic_client`
--   predicate, added to the one CTE/query the report's revenue and visit totals are built from —
--   nothing else in any of these functions moved):
--     1. public.get_dashboard_summary        — scoped_sales (revenue_cents/visits/
--        unique_customers all derive from it).
--     2. public.get_dashboard_summary_v154   — same shape (plus repeat_customers/
--        repeat_customer_percentage, which derive from the same scoped_sales -> valid_visits ->
--        visit_days chain).
--     3. public.get_dashboard_summary_v155   — same shape as v154.
--     4. app.v176_sales_window               — valid_sales (net_revenue_cents, revenue_
--        transactions, visits, customers_served, average_order_cents all derive from it).
--     5. app.v177_sales_window               — same shape as v176 (branch-scoped twin;
--        app.v177_overview calls v176/v177_sales_window and needed no separate edit — it has no
--        direct `public.sales` read of its own).
--     6. public.platform_get_assigned_firm_report_v94 — valid_sales (kpis.net_revenue_cents,
--        kpis.visits, kpis.average_order_cents, and — via customer_metrics's left join —
--        preferences.services/products all derive from it). `data_quality.synthetic_excluded`
--        already claimed `true` in this function's own output; it was false until this fix.
--     7. public.retention_lapsed_candidates_v244 — visit_rows had NO client filter of any kind
--        (unlike v548/v550's already-correct pattern); net_visits and the p_min_visits gate both
--        counted a synthetic client's sales.
--     8. public.refresh_growth_recommendation_v108 — the 90-day `v_total_revenue`/
--        `v_identified_revenue`/`v_total_sales`/`v_identified_sales` block (exposed as
--        `total_revenue_cents_90d`/`identified_revenue_cents_90d`) read every sale in the window
--        with no client filter at all. The separate `canonical_sales` CTE that drives per-client
--        recommendation candidates already runs 200+ days of independent gating (policy
--        eligibility, suppression, dedupe) and is NOT touched here — whether a synthetic client
--        should ever be a recommendation candidate is a candidate-eligibility question, not a
--        revenue/visit-total correctness question, and no fixture in this corpus exercises it;
--        left as a named, owed follow-up rather than silently bundled into this fix.
--
-- Every patch below is an anchored, comment-free replace-equality diff against the LIVE
-- pg_get_functiondef body — same discipline as nestly_v668/v687/v714/v724: capture the body
-- before, apply CREATE OR REPLACE, then assert the new body equals old-with-exactly-this-
-- substitution-and-nothing-else, or roll back the whole migration.
--
-- PROVEN BY: db/tests/executed/v734_corpus_synthetic_exclusion.sql — one business, 5 real
-- clients whose sales total exactly 50000 cents over 8 distinct visit-days, plus one synthetic
-- client whose 3 sales total 10000 cents over 3 more distinct days. Every touched reader (plus
-- get_revenue_truth_v106, as the control) must report 50000/8, never the naive 60000/11.
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block's comment, or restore
-- from the prior migration in the chain that last touched that function).

begin;

create temp table _v734_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v734_before(fn, def)
  select 'get_dashboard_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary' and p.pronargs = 4
  union all
  select 'get_dashboard_summary_v154', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v154'
  union all
  select 'get_dashboard_summary_v155', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v155'
  union all
  select 'v176_sales_window', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v176_sales_window'
  union all
  select 'v177_sales_window', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v177_sales_window'
  union all
  select 'platform_get_assigned_firm_report_v94', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_get_assigned_firm_report_v94'
  union all
  select 'retention_lapsed_candidates_v244', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'retention_lapsed_candidates_v244'
  union all
  select 'refresh_growth_recommendation_v108', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_growth_recommendation_v108';

  if (select count(*) from _v734_before) <> 8 then
    raise exception 'v734: expected exactly 8 captured function bodies, found %',
      (select count(*) from _v734_before);
  end if;
  if exists (select 1 from _v734_before where def ilike '%is_synthetic_client%') then
    raise exception 'v734: a target function already carries the exclusion — stop and re-read '
      'before shipping';
  end if;
end
$capture$;

-- =============================================================================================
-- 1 · public.get_dashboard_summary
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module(p_business, 'dailyreport') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'loyalty'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'sales'
  );
  if not v_sales_available then
    return jsonb_build_object(
      'availability', jsonb_build_object(
        'sales', false,
        'clients', false,
        'loyalty', false,
        'credit_liability', false
      ),
      'scope', jsonb_build_object(
        'timezone', 'Asia/Singapore',
        'from', p_from,
        'to', p_to,
        'branch_id', p_branch,
        'status', 'unavailable_incomplete_sales_scope'
      )
    );
  end if;

  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
    ) else null end,
    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      where cb.business_id = p_business
    ) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays
  from generate_series(1, 7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'day', d.sale_day,
      'amount_cents', coalesce(r.amount_cents, 0)
    ) order by d.sale_day),
    '[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) r using (sale_day);

  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business;

  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday', v_weekdays,
    'revenue_by_day', v_revenue_by_day,
    'gender_counts', v_gender,
    'age_counts', v_age,
    'availability', jsonb_build_object(
      'sales', true,
      'clients', v_clients_available,
      'loyalty', v_loyalty_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'visits', 'selected_period_and_branch_valid_originals',
      'revenue', 'selected_period_and_branch_signed_ledger',
      'unique_customers', 'selected_period_and_branch_customer_records_with_valid_visits',
      'new_customers', case when v_clients_available then 'business_wide_records_added_in_selected_period' else 'unavailable_without_complete_clients_scope' end,
      'points_issued', case
        when not v_loyalty_available then 'unavailable_without_complete_loyalty_scope'
        when p_branch is null then 'business_wide_gross_earn_in_selected_period'
        else 'selected_branch_sale_linked_gross_earn_in_selected_period'
      end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_signed_credit_ledger_with_complete_business_sales_read'
        else 'unavailable_without_complete_business_sales_scope' end,
      'age_counts', case when v_clients_available then 'business_wide_current' else 'unavailable_without_complete_clients_scope' end
    )
  );
end;
$function$;

do $check1$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and (p_branch is null or s.branch_id = p_branch)
  ), valid_visits as (
';
  v_new constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
  ), valid_visits as (
';
begin
  select def into v_before from _v734_before where fn = 'get_dashboard_summary';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary' and p.pronargs = 4;
  if position(v_old in v_before) = 0 then
    raise exception 'v734/get_dashboard_summary: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/get_dashboard_summary: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check1$;

-- =============================================================================================
-- 2 · public.get_dashboard_summary_v154
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_summary_v154(p_business uuid, p_from date, p_to date, p_scope_mode text DEFAULT 'current'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_scope_ids uuid[];
  v_scope_label text;
  v_mode text := coalesce(nullif(btrim(p_scope_mode),''),'current');
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
begin
  if auth.uid() is null or not app.has_perm(p_business,'view_sales') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required' using errcode='22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v154(
    p_business,v_mode,p_branch_ids,p_operational_branch
  ) scope;
  if cardinality(v_scope_ids) = 0 then
    raise exception 'no_authorised_reporting_branches' using errcode='42501';
  end if;
  v_scope_label := app.reporting_scope_label_v154(
    p_business,v_mode,p_branch_ids,p_operational_branch
  );

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, case when cardinality(v_scope_ids)=1 then v_scope_ids[1] else null end, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, case when cardinality(v_scope_ids)=1 then v_scope_ids[1] else null end, 'loyalty'
  );

  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
      and not sc.is_synthetic_client
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points),0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and ps.branch_id = any(v_scope_ids)
    ) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits,0) order by d.day_no),'[]'::jsonb)
  into v_weekdays
  from generate_series(1,7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(jsonb_agg(jsonb_build_object(
    'day',d.sale_day,
    'amount_cents',coalesce(r.amount_cents,0)
  ) order by d.sale_day),'[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
    group by 1
  ) r using (sale_day);

  if v_clients_available then
    with scoped_customers as (
      select distinct s.client_id
      from public.sales s
      where s.business_id = p_business
        and s.client_id is not null
        and s.counts_as_visit
        and s.reversal_of is null
        and s.branch_id = any(v_scope_ids)
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=s.business_id
            and reversal.reversal_of=s.id
        )
    )
    select jsonb_build_object(
      'female', count(*) filter (where c.gender='female'),
      'male', count(*) filter (where c.gender='male'),
      'other', count(*) filter (where c.gender='other'),
      'unknown', count(*) filter (where c.gender is null)
    )
    into v_gender
    from public.clients c
    join scoped_customers scoped on scoped.client_id = c.id
    where c.business_id = p_business;

    with scoped_customers as (
      select distinct s.client_id
      from public.sales s
      where s.business_id = p_business
        and s.client_id is not null
        and s.counts_as_visit
        and s.reversal_of is null
        and s.branch_id = any(v_scope_ids)
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=s.business_id
            and reversal.reversal_of=s.id
        )
    )
    select jsonb_build_object(
      'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) < 25),
      'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 25 and 34),
      'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 35 and 44),
      'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 45 and 54),
      'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) >= 55),
      'unknown', count(*) filter (where c.birth_date is null)
    )
    into v_age
    from public.clients c
    join scoped_customers scoped on scoped.client_id = c.id
    where c.business_id = p_business;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday',v_weekdays,
    'revenue_by_day',v_revenue_by_day,
    'gender_counts',v_gender,
    'age_counts',v_age,
    'availability',jsonb_build_object(
      'sales',v_sales_available,
      'clients',v_clients_available,
      'loyalty',v_loyalty_available
    ),
    'scope',jsonb_build_object(
      'mode',v_mode,
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'operational_branch_id',p_operational_branch,
      'timezone','Asia/Singapore',
      'from',p_from,
      'to',p_to,
      'revenue','selected_reporting_scope_signed_ledger',
      'visits','selected_reporting_scope_valid_originals',
      'unique_customers','deduplicated canonical customer IDs with valid visits in scope',
      'repeat_customer_percentage','recalculated from combined source records; percentages are not summed',
      'new_customers','business_wide_records_added_in_selected_period'
    )
  );
end
$function$;

do $check2$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and s.branch_id = any(v_scope_ids)
  ), valid_visits as (
';
  v_new constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and s.branch_id = any(v_scope_ids)
      and not sc.is_synthetic_client
  ), valid_visits as (
';
begin
  select def into v_before from _v734_before where fn = 'get_dashboard_summary_v154';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v154';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/get_dashboard_summary_v154: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/get_dashboard_summary_v154: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check2$;

-- =============================================================================================
-- 3 · public.get_dashboard_summary_v155
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_summary_v155(p_business uuid, p_from date, p_to date, p_scope_mode text DEFAULT 'current'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_scope_ids uuid[];
  v_scope_label text;
  v_mode text := coalesce(nullif(btrim(p_scope_mode),''),'current');
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
begin
  if auth.uid() is null or not app.has_perm(p_business,'view_sales') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode='42501';
  end if;
  -- nestly_v570: the ROLE perm above is not the whole answer. An owner can switch a teammate's
  -- Dashboard module to Off in the per-staff module editor, and every 'staff' role still carries
  -- view_sales -- so this function happily served the denied teammate the firm's revenue, visit
  -- counts and customer mix. The module permission is the owner's decision and it is enforced
  -- HERE, at the reader, because hiding the rail entry is a display preference and this is the
  -- boundary. app.can_module is the same authority the rest of the workspace asks: an owner
  -- always passes, a staff row that inherits (modules is null, no module_perms map) always
  -- passes, and only an explicit denial is refused -- so no existing account loses the dashboard.
  if not app.can_module(p_business,'dashboard') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required' using errcode='22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,v_mode,p_branch_ids,p_operational_branch
  ) scope;
  if cardinality(v_scope_ids) = 0 then
    raise exception 'no_authorised_reporting_branches' using errcode='42501';
  end if;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,v_mode,p_branch_ids,p_operational_branch
  );

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, case when cardinality(v_scope_ids)=1 then v_scope_ids[1] else null end, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, case when cardinality(v_scope_ids)=1 then v_scope_ids[1] else null end, 'loyalty'
  );

  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
      and not sc.is_synthetic_client
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points),0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.programme_id = app.live_balance_programme_v381(p_business)
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and ps.branch_id = any(v_scope_ids)
    ) else null end,
    'loyalty_unit', case when v_loyalty_available then (select spine.kind from public.business_programmes spine where spine.id = app.live_balance_programme_v381(p_business)) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits,0) order by d.day_no),'[]'::jsonb)
  into v_weekdays
  from generate_series(1,7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(jsonb_agg(jsonb_build_object(
    'day',d.sale_day,
    'amount_cents',coalesce(r.amount_cents,0)
  ) order by d.sale_day),'[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
    group by 1
  ) r using (sale_day);

  if v_clients_available then
    with scoped_customers as (
      select distinct s.client_id
      from public.sales s
      where s.business_id = p_business
        and s.client_id is not null
        and s.counts_as_visit
        and s.reversal_of is null
        and s.branch_id = any(v_scope_ids)
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=s.business_id
            and reversal.reversal_of=s.id
        )
    )
    select jsonb_build_object(
      'female', count(*) filter (where c.gender='female'),
      'male', count(*) filter (where c.gender='male'),
      'other', count(*) filter (where c.gender='other'),
      'unknown', count(*) filter (where c.gender is null)
    )
    into v_gender
    from public.clients c
    join scoped_customers scoped on scoped.client_id = c.id
    where c.business_id = p_business;

    with scoped_customers as (
      select distinct s.client_id
      from public.sales s
      where s.business_id = p_business
        and s.client_id is not null
        and s.counts_as_visit
        and s.reversal_of is null
        and s.branch_id = any(v_scope_ids)
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id=s.business_id
            and reversal.reversal_of=s.id
        )
    )
    select jsonb_build_object(
      'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) < 25),
      'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 25 and 34),
      'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 35 and 44),
      'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) between 45 and 54),
      'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore',now()))::date,c.birth_date)) >= 55),
      'unknown', count(*) filter (where c.birth_date is null)
    )
    into v_age
    from public.clients c
    join scoped_customers scoped on scoped.client_id = c.id
    where c.business_id = p_business;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday',v_weekdays,
    'revenue_by_day',v_revenue_by_day,
    'gender_counts',v_gender,
    'age_counts',v_age,
    'availability',jsonb_build_object(
      'sales',v_sales_available,
      'clients',v_clients_available,
      'loyalty',v_loyalty_available
    ),
    'scope',jsonb_build_object(
      'mode',v_mode,
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'operational_branch_id',p_operational_branch,
      'timezone','Asia/Singapore',
      'from',p_from,
      'to',p_to,
      'revenue','selected_reporting_scope_signed_ledger',
      'visits','selected_reporting_scope_valid_originals',
      'unique_customers','deduplicated canonical customer IDs with valid visits in scope',
      'repeat_customer_percentage','recalculated from combined source records; percentages are not summed',
      'new_customers','business_wide_records_added_in_selected_period'
    )
  );
end
$function$;

do $check3$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and s.branch_id = any(v_scope_ids)
  ), valid_visits as (
';
  v_new constant text := E'  with scoped_sales as (
    select s.*
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone \'Asia/Singapore\')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone \'Asia/Singapore\')
      and s.branch_id = any(v_scope_ids)
      and not sc.is_synthetic_client
  ), valid_visits as (
';
begin
  select def into v_before from _v734_before where fn = 'get_dashboard_summary_v155';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v155';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/get_dashboard_summary_v155: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/get_dashboard_summary_v155: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check3$;

-- =============================================================================================
-- 4 · app.v176_sales_window
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v176_sales_window(p_business uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
    'customers_served', (
      select count(distinct client_id)
      from valid_sales where client_id is not null
    ),
    'average_order_cents', coalesce(
      (select round(avg(amount_cents))::bigint
       from valid_sales where counts_as_revenue), 0
    ),
    'new_customers', (
      select count(*) from first_purchase
      where first_purchase.first_date between p_from and p_to
    )
  )
$function$;

do $check4$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
';
  v_new constant text := E'  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
';
begin
  select def into v_before from _v734_before where fn = 'v176_sales_window';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v176_sales_window';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/v176_sales_window: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/v176_sales_window: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check4$;

-- =============================================================================================
-- 5 · app.v177_sales_window
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v177_sales_window(p_business uuid, p_branch uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
    'customers_served', (
      select count(distinct client_id)
      from valid_sales where client_id is not null
    ),
    'average_order_cents', coalesce(
      (select round(avg(amount_cents))::bigint
       from valid_sales where counts_as_revenue), 0
    ),
    'new_customers', (
      select count(*) from first_purchase
      where first_purchase.first_date between p_from and p_to
    )
  )
$function$;

do $check5$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
';
  v_new constant text := E'  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
';
begin
  select def into v_before from _v734_before where fn = 'v177_sales_window';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v177_sales_window';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/v177_sales_window: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/v177_sales_window: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check5$;

-- =============================================================================================
-- 6 · public.platform_get_assigned_firm_report_v94
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_get_assigned_firm_report_v94(p_business uuid, p_branch uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_result jsonb;v_from timestamptz;v_to timestamptz;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_report_window' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.*
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      count(distinct app.ci_visit_day_v699(valid_sales.occurred_at)) filter (where valid_sales.counts_as_visit) visit_days,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
  ), classified as (
    select customer_metrics.*,
      case
        when purchases=1
          and first_purchase_at>=(p_to-29)::timestamp at time zone 'Asia/Singapore'
          then 'new'
        when purchases>=5
          and last_purchase_at>=(p_to-29)::timestamp at time zone 'Asia/Singapore'
          then 'champions'
        when purchases>=2
          and last_purchase_at>=(p_to-59)::timestamp at time zone 'Asia/Singapore'
          then 'loyal'
        when purchases>=2
          and last_purchase_at>=(p_to-89)::timestamp at time zone 'Asia/Singapore'
          then 'at_risk'
        when last_purchase_at<(p_to-89)::timestamp at time zone 'Asia/Singapore'
          then 'lapsed'
        else 'other'
      end cohort
    from customer_metrics
  ), identified_n as (
    select count(*)::int as n from customer_metrics
  ), evidence_block as (
    select app.subgroup_evidence_v1(identified_n.n) as evidence,
      (app.subgroup_evidence_v1(identified_n.n)->>'status') = 'insufficient' as insufficient
    from identified_n
  ), preference_rows as (
    select item.item_type,item.ref_id,
      coalesce(
        max(case when item.item_type='service' then service.name
                 when item.item_type='retail' then product.name end),
        max(item.description),'Unlabelled item'
      ) item_name,
      count(distinct item.sale_id) orders,sum(item.qty) units,
      sum(item.line_cents) revenue_cents
    from public.sale_items item
    join valid_sales sale on sale.id=item.sale_id
    left join public.services service
      on item.item_type='service' and service.id=item.ref_id
        and service.business_id=p_business
    left join public.products product
      on item.item_type='retail' and product.id=item.ref_id
        and product.business_id=p_business
    where item.business_id=p_business
      and item.item_type in ('service','retail')
    group by item.item_type,item.ref_id
  ), ranked_preferences as (
    select preference_rows.*,
      row_number() over(
        partition by item_type
        order by orders desc,revenue_cents desc,ref_id nulls last,item_name
      ) preference_rank
    from preference_rows
  ), preferences as (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'item_id',ref_id,'name',item_name,'orders',orders,'units',units,
        'revenue_cents',revenue_cents
      ) order by preference_rank) filter(
        where item_type='service' and preference_rank<=5
      ),'[]'::jsonb) services,
      coalesce(jsonb_agg(jsonb_build_object(
        'item_id',ref_id,'name',item_name,'orders',orders,'units',units,
        'revenue_cents',revenue_cents
      ) order by preference_rank) filter(
        where item_type='retail' and preference_rank<=5
      ),'[]'::jsonb) products
    from ranked_preferences
  )
  select jsonb_build_object(
    'scope',jsonb_build_object(
      'business_id',business.id,'business_name',business.name,
      'branch_id',p_branch,'from',p_from,'to',p_to
    ),
    'kpis',jsonb_build_object(
      'net_revenue_cents',coalesce((select sum(amount_cents)
        from valid_sales where counts_as_revenue),0),
      'visits',(select count(distinct (client_id, app.ci_visit_day_v699(occurred_at))) filter (where client_id is not null and counts_as_visit) + count(*) filter (where client_id is null and counts_as_visit) from valid_sales),
      'active_customers',(select count(*) from customer_metrics where purchases>0),
      'returning_customers',(select count(*) from customer_metrics where visit_days>=2),
      'average_order_cents',
        case when evidence_block.insufficient then null
        else coalesce((select round(avg(amount_cents))::bigint
          from valid_sales where counts_as_revenue),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),
    'cohorts',jsonb_build_object(
      'definitions',jsonb_build_object(
        'champions','5+ purchases; last purchase in final 30 days',
        'loyal','2-4 purchases; last purchase in final 60 days',
        'at_risk','2+ purchases; last purchase 61-90 days before report end',
        'new','exactly 1 purchase; first purchase in final 30 days',
        'lapsed','last purchase more than 90 days before report end',
        'other','does not meet a named cohort'
      ),
      'counts',jsonb_build_object(
        'champions',(select count(*) from classified where cohort='champions'),
        'loyal',(select count(*) from classified where cohort='loyal'),
        'at_risk',(select count(*) from classified where cohort='at_risk'),
        'new',(select count(*) from classified where cohort='new'),
        'lapsed',(select count(*) from classified where cohort='lapsed'),
        'other',(select count(*) from classified where cohort='other')
      ),
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),
    'preferences',jsonb_build_object(
      'services',preferences.services,'products',preferences.products
    ),
    'customer_intelligence',jsonb_build_object(
      'total_customers',(select count(*) from customer_metrics),
      'customers_with_purchase',(select count(*) from customer_metrics where purchases>0),
      'customers_over_90_days_inactive',(select count(*) from classified
        where cohort='lapsed'),
      'top_customer_revenue_cents',
        case when evidence_block.insufficient then null
        else coalesce((select max(revenue_cents)
          from customer_metrics),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),
    'data_quality',jsonb_build_object(
      'synthetic_excluded',true,'reversed_sales_excluded',true,
      'timezone','Asia/Singapore','cohort_anchor',p_to
    )
  ) into v_result
  from public.businesses business cross join preferences cross join evidence_block
  where business.id=p_business;
  return v_result;
end
$function$;

do $check6$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  with valid_sales as (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
  ), customer_metrics as (
';
  v_new constant text := E'  with valid_sales as (
    select sale.*
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not sc.is_synthetic_client
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
  ), customer_metrics as (
';
begin
  select def into v_before from _v734_before where fn = 'platform_get_assigned_firm_report_v94';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_get_assigned_firm_report_v94';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/platform_get_assigned_firm_report_v94: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/platform_get_assigned_firm_report_v94: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check6$;

-- =============================================================================================
-- 7 · public.retention_lapsed_candidates_v244
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.retention_lapsed_candidates_v244(p_business uuid, p_lapsed_days integer, p_min_visits integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_cap constant integer := 20000;
  v_lapsed integer := greatest(1, least(365, coalesce(p_lapsed_days, 45)));
  v_min integer := greatest(1, least(99, coalesce(p_min_visits, 3)));
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_total bigint;
  v_rows jsonb;
begin
  -- Same gate the browser applied before its raw table reads (raises 42501).
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
    -- validVisitSales: reversals are never visits; a reversed original is out.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  per_client as (
    select vv.client_id,
           count(distinct app.ci_visit_day_v699(vv.occurred_at))::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
  ),
  candidates as (
    select c.id, c.full_name, c.phone,
           pc.net_visits,
           greatest(0, v_today - (pc.last_visit_at at time zone 'Asia/Singapore')::date)::integer
             as last_visit_days
    from per_client pc
    join public.clients c
      on c.id = pc.client_id and c.business_id = p_business
    where pc.net_visits >= v_min
      and greatest(0, v_today - (pc.last_visit_at at time zone 'Asia/Singapore')::date) >= v_lapsed
  )
  select count(*),
         coalesce(jsonb_agg(x.row order by x.last_visit_days desc, x.id)
                    filter (where x.rank <= v_cap), '[]'::jsonb)
    into v_total, v_rows
    from (
      select cand.id, cand.last_visit_days,
             row_number() over (order by cand.last_visit_days desc, cand.id) as rank,
             jsonb_build_object(
               'id', cand.id,
               'full_name', cand.full_name,
               'phone', cand.phone,
               'net_visits', cand.net_visits,
               'last_visit_days', cand.last_visit_days
             ) as row
      from candidates cand
    ) x;

  return jsonb_build_object(
    'candidates', v_rows,
    'total', coalesce(v_total, 0),
    'truncated', coalesce(v_total, 0) > v_cap
  );
end;
$function$;

do $check7$
declare v_before text; v_after text; v_expected text;
  v_old constant text := E'  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit = true
  ),
';
  v_new constant text := E'  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_visit = true
      and not sc.is_synthetic_client
  ),
';
begin
  select def into v_before from _v734_before where fn = 'retention_lapsed_candidates_v244';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'retention_lapsed_candidates_v244';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/retention_lapsed_candidates_v244: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v734/retention_lapsed_candidates_v244: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check7$;

-- =============================================================================================
-- 8 · public.refresh_growth_recommendation_v108 — only the 90-day revenue aggregate block.
--     The rest of the (much larger) function body is captured/verified byte-for-byte unchanged
--     by the same replace-equality check below.
-- =============================================================================================
do $fn8$
declare
  v_before text;
  v_after  text;
  v_expected text;
  v_old constant text := E'  select
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue),0),
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue and sale.client_id is not null),0),
    count(*) filter(where sale.counts_as_revenue),
    count(*) filter(where sale.counts_as_revenue and sale.client_id is not null)
  into v_total_revenue,v_identified_revenue,v_total_sales,v_identified_sales
  from public.sales sale
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.occurred_at>=v_now-interval \'90 days\'
    and sale.occurred_at<v_now
    and sale.reversal_of is null
    and not exists (
      select 1 from public.sales reversal
       where reversal.business_id=sale.business_id
         and reversal.reversal_of=sale.id
    );
';
  v_new constant text := E'  select
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue),0),
    coalesce(sum(app.v106_sale_residual_minor(sale.id,v_now))
      filter(where sale.counts_as_revenue and sale.client_id is not null),0),
    count(*) filter(where sale.counts_as_revenue),
    count(*) filter(where sale.counts_as_revenue and sale.client_id is not null)
  into v_total_revenue,v_identified_revenue,v_total_sales,v_identified_sales
  from public.sales sale
  cross join lateral app.analytics_sale_class_v1(sale) sc
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.occurred_at>=v_now-interval \'90 days\'
    and sale.occurred_at<v_now
    and sale.reversal_of is null
    and not sc.is_synthetic_client
    and not exists (
      select 1 from public.sales reversal
       where reversal.business_id=sale.business_id
         and reversal.reversal_of=sale.id
    );
';
  v_ddl text;
begin
  select def into v_before from _v734_before where fn = 'refresh_growth_recommendation_v108';
  if position(v_old in v_before) = 0 then
    raise exception 'v734/refresh_growth_recommendation_v108: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);

  -- CREATE OR REPLACE using the captured live body with the substitution applied — avoids
  -- hand-retyping ~470 lines of an unrelated function for a one-CTE fix. v_expected already IS
  -- "CREATE OR REPLACE FUNCTION ... AS $function$ ... $function$" (pg_get_functiondef's own
  -- output shape), so it is directly executable DDL.
  execute v_expected;

  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_growth_recommendation_v108';
  if v_after <> v_expected then
    raise exception 'v734/refresh_growth_recommendation_v108: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$fn8$;

-- =============================================================================================
-- 9 · ACL restated verbatim for every function actually re-emitted via CREATE OR REPLACE above
--     (CREATE OR REPLACE preserves existing grants; stated explicitly per house style).
-- =============================================================================================
revoke all on function public.get_dashboard_summary(uuid, date, date, uuid) from public, postgres, authenticated, service_role;
grant execute on function public.get_dashboard_summary(uuid, date, date, uuid) to postgres, authenticated, service_role;

revoke all on function public.get_dashboard_summary_v154(uuid, date, date, text, uuid[], uuid) from public, postgres, authenticated, service_role;
grant execute on function public.get_dashboard_summary_v154(uuid, date, date, text, uuid[], uuid) to postgres, authenticated, service_role;

revoke all on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid) from public, postgres, authenticated, service_role;
grant execute on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid) to postgres, authenticated, service_role;

revoke all on function app.v176_sales_window(uuid, date, date) from public, postgres, authenticated, service_role;
grant execute on function app.v176_sales_window(uuid, date, date) to postgres, authenticated, service_role;

revoke all on function app.v177_sales_window(uuid, uuid, date, date) from public, postgres, authenticated, service_role;
grant execute on function app.v177_sales_window(uuid, uuid, date, date) to postgres, authenticated, service_role;

revoke all on function public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date) from public, postgres, authenticated, service_role;
grant execute on function public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date) to postgres, authenticated, service_role;

revoke all on function public.retention_lapsed_candidates_v244(uuid, integer, integer) from public, postgres, authenticated, service_role;
grant execute on function public.retention_lapsed_candidates_v244(uuid, integer, integer) to postgres, authenticated, service_role;

revoke all on function public.refresh_growth_recommendation_v108(uuid, uuid) from public, postgres, authenticated, service_role;
grant execute on function public.refresh_growth_recommendation_v108(uuid, uuid) to postgres, authenticated, service_role;

commit;
