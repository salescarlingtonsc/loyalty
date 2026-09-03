-- NESTLY v740 — synthetic-client exclusion, estate sweep 3 (CI-100 checklist checks 1, 5, 10).
-- Continues nestly_v687/v734/v737. A refuter's scenario (owner principal for public.* firm
-- readers, staff principal for staff_* readers, SA-with-Google for platform_* readers; 5 real
-- clients / 50000 cents / 8 visit-days, 1 synthetic client with 3 sales one fully reversed via a
-- native reversal_of row (unreversed net 6000), 2 anonymous sales / 10000 cents) found SEVEN more
-- readers still leaking a synthetic client's real sales into a reported total or roster, plus TWO
-- more found by this migration's own estate scan (grep is not proof — every one below was proven
-- broken by executing it against the scenario before this migration, not by pattern-matching):
--
--   1. public.get_reports_summary          — the revenue_by_kind aggregate (`v_revenue`) read
--      every sale in the window with no population predicate at all: 66000 instead of 60000
--      known (identified 50000 + anonymous 10000, synthetic's net 6000 excluded).
--   2. public.staff_list_customers_v154    — `customer_rows` selected `from public.clients
--      customer` with no is_synthetic filter: total=6 and the synthetic client appeared in the
--      roster.
--   3. public.staff_list_customers_v155    — same shape as v154: total=6, synthetic listed.
--   4. public.staff_customer_bucket_counts_v290 — same `customer_rows` shape (no full_name/phone
--      projected, but the same unfiltered `from public.clients customer`): counts.total=6.
--   5. public.get_customer_identity_coverage_v111 — reads `public.sales s` directly with no
--      client-population predicate: eligible/identified transaction counts and both the raw and
--      canonical identified-customer counts included the synthetic client's 2 unreversed sales
--      and its 1 identified customer, landing at 6 instead of 5.
--   6. public.platform_generate_my_report_v89 — the summary AND the per-business `businesses[]`
--      revenue figure were gross (`reversal_of is null and counts_as_revenue`, which does NOT
--      exclude an ORIGINAL sale that has since been reversed by a later row — see
--      app.analytics_sale_class_v1.include_revenue, which correctly does) and did not exclude
--      synthetic clients either: 70000 instead of 60000 (identified 50000 + anonymous 10000,
--      with the reversed 4000 correctly dropped and the unreversed synthetic 6000 correctly
--      excluded). customer_count/customers were 6 instead of 5.
--   7. public.platform_get_catalogue_affinity_v94 — both `valid_sales` CTEs (the readiness-metric
--      one and the pairing one, identical bodies, kept in sync since v49/v94's own convention)
--      read `public.sales sale` with no synthetic predicate: readiness.observed.customers=6.
--
--   Found by this migration's own estate scan (every function in public+app whose live
--   pg_get_functiondef body reads `from public.sales`/`from public.sale_items`, checked by
--   executing it against the same scenario, not by grepping for the word "synthetic"):
--
--   8. public.get_revenue_summary          — `v_accrual` (the headline revenue_accrual_cents)
--      and the `revenue` CTE feeding `monthly[].revenue_accrual_cents` both read `public.sales s`
--      with no synthetic predicate: 66000 instead of 60000.
--   9. public.get_studio_sales_baseline_v145 — the trailing-30-day owner-only sales baseline
--      (`count30`/`avg_bill_cents`) read `public.sales sale` with no synthetic predicate: with
--      this fixture's dates placed inside the function's fixed `now() - interval '30 days'`
--      window, count30=12/avg_bill_cents=5500 instead of count30=10/avg_bill_cents=6000.
--
-- ALREADY CORRECT, or already fixed by an earlier migration and confirmed still live during this
-- scan (verified by reading the live body, not re-touched): every get_ci_*_v1 / app.ci_*_v1
-- reader, app.v176/v177_sales_window, app.v177_customers, public.get_attention_list_v548,
-- public.get_recovery_report_v550, public.retention_lapsed_candidates_v244,
-- public.refresh_growth_recommendation_v108, public.platform_get_assigned_firm_report_v94,
-- public.platform_generate_improvement_report_v82, public.platform_get_enterprise_hierarchy_v82,
-- public.platform_list_enterprise_customers_v82, public.get_dashboard_summary(_v154/_v155) (all
-- nestly_v734), app.v179_business_insights.
--
-- NAMED, OWED FOLLOW-UPS (found reading this estate scan's output, NOT fixed here — each needs
-- its own fixture before a fix can be trusted, and this migration's job is the seven scenario-
-- proven stragglers plus what could be proven with the SAME fixture, not a silent grab-bag):
--   * public.get_revenue_truth_v106 and public.get_customer_intelligence_v83 already have WRITTEN
--     fixes on disk for this exact defect (nestly_v687, nestly_v737) that this scan's live-body
--     check confirms are NOT YET APPLIED to this database — an apply/deploy gap, not a missing
--     fix, and out of this migration's scope.
--   * public.staff_list_returned_customers_v300 — `visit_rows` has no client filter, so a
--     synthetic client that closes a qualifying away-then-return gap would appear in
--     `total_returned`/`rows`. Confirmed broken by reading the body (same unfiltered-CTE shape as
--     v244 before nestly_v734); NOT fixed here because proving it needs a dedicated gap-and-
--     return fixture (a specific away/window day arrangement for the synthetic client) that does
--     not fit inside this migration's shared single-scenario fixture without changing what every
--     other assertion in it means.
--   * public.get_customer_lifecycle_v107, public.get_period_economics_v109,
--     public.get_revenue_driver_decomposition_v109, public.customer_get_business_presentation_v95,
--     public.preview_campaign_audience_v155, public.staff_list_customers_v129,
--     public.get_campaign_results, app.get_growth_execution_result_at_v108 — all read
--     `public.sales`/`public.sale_items` with aggregation and no visible synthetic predicate in
--     the live body; none were reachable inside this migration's time budget with proof-by-
--     execution rather than by inspection, so none are touched. Each is a real candidate for the
--     next estate-sweep migration.
--   * public.get_reports_summary_v94_base carries the identical unfiltered `v_revenue` bug as
--     item 1 above, but its live grant set is `postgres:EXECUTE` only (no anon/authenticated/
--     service_role grant) and no other function in the estate calls it — it is unreachable by any
--     principal today, so it is left alone rather than touched for its own sake; flagged so it is
--     not rediscovered as a false "fix" candidate later.
--
-- Every patch below is an anchored, comment-free replace-equality diff against the LIVE
-- pg_get_functiondef body — same discipline as nestly_v668/v687/v714/v724/v734/v737: capture the
-- body before, apply CREATE OR REPLACE, then assert the new body equals old-with-exactly-this-
-- substitution-and-nothing-else, or roll back the whole migration. ACLs are restated exactly as
-- they already are (CREATE OR REPLACE preserves existing grants; nothing here widens or narrows
-- anon/authenticated/service_role access, and app.analytics_sale_class_v1 itself is untouched).
--
-- PROVEN BY: db/tests/executed/v740_corpus_synthetic_estate_3.sql — one business, the same 5 real
-- clients / 50000 cents / 8 visit-days shape v734/v737 use, plus one synthetic client with 3
-- sales (one fully reversed via a native reversal_of row, unreversed net 6000) and 2 anonymous
-- sales (10000 cents), each reader called as its real principal (owner for firm reports, a
-- non-owner staff row for staff_* readers, an SA-with-Google session for platform_* readers).
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block's comment).

begin;

create temp table _v740_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v740_before(fn, def)
  select 'get_reports_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary' and p.pronargs = 4
  union all
  select 'staff_list_customers_v154', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v154'
  union all
  select 'staff_list_customers_v155', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v155'
  union all
  select 'staff_customer_bucket_counts_v290', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_customer_bucket_counts_v290'
  union all
  select 'get_customer_identity_coverage_v111', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_identity_coverage_v111'
  union all
  select 'platform_generate_my_report_v89', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_generate_my_report_v89'
  union all
  select 'platform_get_catalogue_affinity_v94', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_get_catalogue_affinity_v94'
  union all
  select 'get_revenue_summary', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_revenue_summary'
  union all
  select 'get_studio_sales_baseline_v145', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_studio_sales_baseline_v145';

  if (select count(*) from _v740_before) <> 9 then
    raise exception 'v740: expected exactly 9 captured function bodies, found %',
      (select count(*) from _v740_before);
  end if;
  if exists (select 1 from _v740_before where def ilike '%is_synthetic%') then
    raise exception 'v740: a target function already carries a synthetic-client exclusion — '
      'stop and re-read before shipping';
  end if;
end
$capture$;

-- =============================================================================================
-- 1 · public.get_reports_summary
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_reports_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
  v_compensating_rows bigint;
  v_reversed_revenue_cents bigint;
  v_net_revenue_cents bigint;
  v_sales_export_available boolean;
  v_clients_export_available boolean;
  v_loyalty_available boolean;
  v_gift_cards_available boolean;
  v_memberships_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales') then
    raise exception 'you do not have permission to view reports for this business'
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

  -- Every money/reversal field below is derived from Sales. Reports mode alone is not
  -- sufficient because a branch-level Sales override may intentionally make that
  -- source unreadable. A SECURITY DEFINER aggregate must fail closed for the exact
  -- selected scope rather than return a plausible complete total from hidden rows.
  perform app.require_metric_module_scope_v145(
    p_business, p_branch, 'reports'
  );
  if not app.platform_metric_source_scope_available_v145(
    p_business, p_branch, 'sales'
  ) then
    raise exception 'complete_metric_source_scope_required:sales'
      using errcode = '42501';
  end if;

  v_sales_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_export_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, null, 'loyalty'
  );
  v_gift_cards_available := app.metric_module_scope_available_v145(
    p_business, null, 'giftcards'
  );
  v_memberships_available := app.metric_module_scope_available_v145(
    p_business, null, 'memberships'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'reports'
  ) and app.platform_metric_source_scope_available_v145(
    p_business, null, 'sales'
  );
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;
  -- Preserve the V94 branch-effective Reports boundary. A branch override may
  -- intentionally differ from the firm mode, and an all-branch report must not
  -- consolidate a branch the caller cannot see or where Reports is disabled.
  if p_branch is not null then
    perform app.require_branch_module_v94(p_business, p_branch, 'reports', 'r');
  elsif not app.is_super_admin() then
    if not app.can_module_read_at_v94(p_business, null, 'reports') then
      raise exception 'branch_module_access_required:reports:r'
        using errcode = '42501';
    end if;
    if exists (
      select 1
      from public.branches branch
      where branch.business_id = p_business
        and (
          not app.can_see_branch(p_business, branch.id)
          or not case when branch.active
            then app.can_module_read_at_v94(p_business, branch.id, 'reports')
            else app.can_module_read_at_v94(p_business, null, 'reports')
          end
        )
    ) then
      raise exception 'explicit_branch_required_for_partial_report_scope'
        using errcode = '42501';
    end if;
  end if;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;

  select
    count(*) filter (where s.reversal_of is not null),
    coalesce(sum(-s.amount_cents) filter (
      where s.counts_as_revenue
        and s.reversal_of is not null
        and s.amount_cents < 0
    ), 0),
    coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0)
  into v_compensating_rows, v_reversed_revenue_cents, v_net_revenue_cents
  from public.sales s
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch);

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

  if v_loyalty_available then
    select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
    into v_points
    from (
      select pl.entry_type, sum(pl.points) as points
      from public.points_ledger pl
      where pl.business_id = p_business
        and pl.programme_id = app.live_balance_programme_v381(p_business)
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      group by pl.entry_type
    ) x;
  else
    v_points := null;
  end if;

  if v_credit_liability_available then
    select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      into v_credit_liability
      from public.client_credit_balance cb
     where cb.business_id = p_business;
  else
    v_credit_liability := null;
  end if;

  if v_gift_cards_available then
    v_gift_card_liability := app.reports_gift_card_liability_v49b(
      p_business, p_branch
    );
  else
    v_gift_card_liability := null;
  end if;

  if v_memberships_available then
    select count(*) filter (where m.status = 'active')
    into v_active_memberships
    from public.memberships m
    where m.business_id = p_business;
  else
    v_active_memberships := null;
  end if;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'loyalty_unit', case when v_loyalty_available then (select spine.kind from public.business_programmes spine where spine.id = app.live_balance_programme_v381(p_business)) else null end,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships,
    'reversal_reconciliation', jsonb_build_object(
      'compensating_rows', v_compensating_rows,
      'reversed_revenue_cents', v_reversed_revenue_cents,
      'net_revenue_cents', v_net_revenue_cents
    ),
    'availability', jsonb_build_object(
      'sales_export', v_sales_export_available,
      'clients_export', v_clients_export_available,
      'loyalty', v_loyalty_available,
      'gift_cards', v_gift_cards_available,
      'memberships', v_memberships_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'sales', 'selected_period_and_branch_signed_ledger',
      'points', case when v_loyalty_available
        then 'business_wide_selected_period'
        else 'unavailable_without_complete_loyalty_scope' end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_with_complete_business_reports_and_sales_source_scope'
        else 'unavailable_without_complete_business_reports_and_sales_source_scope' end,
      'gift_card_liability', case when v_gift_cards_available
        then 'business_wide_current' else 'unavailable_without_complete_giftcards_scope' end,
      'active_memberships', case when v_memberships_available
        then 'business_wide_current'
        else 'unavailable_without_complete_memberships_scope' end
    )
  );
end;
$function$;

do $check1$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;$lit$;
  v_new constant text := $lit$  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;$lit$;
begin
  select def into v_before from _v740_before where fn = 'get_reports_summary';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary' and p.pronargs = 4;
  if position(v_old in v_before) = 0 then
    raise exception 'v740/get_reports_summary: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/get_reports_summary: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check1$;

-- =============================================================================================
-- 2 · public.staff_list_customers_v154
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_customers_v154(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_bucket text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_result jsonb;
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;
  if p_inactive_bucket is not null
     and p_inactive_bucket not in ('30_59','60_89','90_plus','never') then
    raise exception 'unsupported_inactivity_bucket' using errcode='22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v154(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v154(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
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
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        coalesce(p_scope_mode,'all') = 'all'
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and visit.last_visit_at is null)
        or (p_inactive_bucket = '30_59' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59)
        or (p_inactive_bucket = '60_89' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89)
        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce(app.client_points_balance_v409(p_business, customer.id), 0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as balance_cents
    from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'definition',case when coalesce(p_scope_mode,'all')='all'
        then 'Business-wide last valid visit across all included authorised branches.'
        else 'Inactive in this branch scope: last valid visit within that selected scope.'
      end
    ),
    'inactive_bucket',p_inactive_bucket,
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'created_at',customer.created_at,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents
    ) order by customer.last_visit_at asc nulls last,customer.full_name,customer.id)
    from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$function$;

do $check2$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        coalesce(p_scope_mode,'all') = 'all'$lit$;
  v_new constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        coalesce(p_scope_mode,'all') = 'all'$lit$;
begin
  select def into v_before from _v740_before where fn = 'staff_list_customers_v154';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v154';
  if position(v_old in v_before) = 0 then
    raise exception 'v740/staff_list_customers_v154: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/staff_list_customers_v154: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check2$;

-- =============================================================================================
-- 3 · public.staff_list_customers_v155
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_customers_v155(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_bucket text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
  -- v381: same pot rule as the customer profile — one programme's balance, not the sum of all
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;
  if p_inactive_bucket is not null
     and p_inactive_bucket not in ('30_59','60_89','90_plus','never','all_inactive') then
    raise exception 'unsupported_inactivity_bucket' using errcode='22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
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
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
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
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business
          and visit.last_visit_at is null)
        or (p_inactive_bucket = '30_59' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59)
        or (p_inactive_bucket = '60_89' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89)
        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
        or (p_inactive_bucket = 'all_inactive' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 30)
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id
          and (v_balance_scope = 'programme_pot' and ledger.programme_id is not distinct from v_live_programme)),0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as balance_cents,
      -- nestly_v629: everything this customer has paid this company, ever. Owner ruling when
      -- asked: "everything the customer paid" — every sale kind, so a package or a membership
      -- counts as the money it was. It is NOT branch-scoped and NOT date-scoped: "lifetime" means
      -- the whole relationship, which is also why it sits beside points and credit here, the two
      -- other business-wide figures on this row, rather than beside the branch-scoped last visit.
      -- Reversals are excluded on BOTH sides — the compensating row and the sale it cancelled —
      -- exactly as visit_facts above excludes them, so a refunded sale leaves no trace in either.
      -- A package SESSION is a SGD 0 sale and therefore adds nothing; the package was already
      -- counted at its full price when it was sold.
      coalesce((select sum(sale.amount_cents) from public.sales sale
        where sale.business_id = p_business and sale.client_id = customer.id
          and sale.reversal_of is null
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id = sale.business_id
              and reversal.reversal_of = sale.id
          )),0)::bigint as lifetime_spend_cents
    from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'definition',case when v_scope_is_whole_business
        then 'Business-wide last valid visit across all included authorised branches.'
        else 'Inactive in this branch scope: last valid visit within that selected scope.'
      end
    ),
    'inactive_bucket',p_inactive_bucket,
    'loyalty_available',app.metric_module_scope_available_v145(p_business,null,'loyalty'),
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'created_at',customer.created_at,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents,
      'lifetime_spend_cents',customer.lifetime_spend_cents
    ) order by customer.last_visit_at asc nulls last,customer.full_name,customer.id)
    from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$function$;

do $check3$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business$lit$;
  v_new constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business$lit$;
begin
  select def into v_before from _v740_before where fn = 'staff_list_customers_v155';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v155';
  if position(v_old in v_before) = 0 then
    raise exception 'v740/staff_list_customers_v155: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/staff_list_customers_v155: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check3$;

-- =============================================================================================
-- 4 · public.staff_customer_bucket_counts_v290
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_customer_bucket_counts_v290(p_business uuid, p_search text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
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
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
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
    select customer.id,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'whole_business',v_scope_is_whole_business
    ),
    'counts',jsonb_build_object(
      '30_59',count(*) filter (
        where days_since_last_visit between 30 and 59),
      '60_89',count(*) filter (
        where days_since_last_visit between 60 and 89),
      '90_plus',count(*) filter (
        where days_since_last_visit >= 90),
      'all_inactive',count(*) filter (
        where days_since_last_visit >= 30),
      'never',count(*) filter (
        where v_scope_is_whole_business and days_since_last_visit is null),
      'active',count(*) filter (
        where days_since_last_visit is not null and days_since_last_visit < 30),
      'total',count(*)
    )
  ) into v_result
  from customer_rows;

  return v_result;
end
$function$;

do $check4$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
  )
  select jsonb_build_object(
    'status','ok',$lit$;
  v_new constant text := $lit$    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
  )
  select jsonb_build_object(
    'status','ok',$lit$;
begin
  select def into v_before from _v740_before where fn = 'staff_customer_bucket_counts_v290';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_customer_bucket_counts_v290';
  if position(v_old in v_before) = 0 then
    raise exception 'v740/staff_customer_bucket_counts_v290: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/staff_customer_bucket_counts_v290: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check4$;

-- =============================================================================================
-- 5 · public.get_customer_identity_coverage_v111
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_customer_identity_coverage_v111(p_business uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_total bigint;
  v_identified bigint;
  v_corrected bigint;
  v_raw_customers bigint;
  v_canonical_customers bigint;
begin
  if auth.uid() is null
     or not app.v111_can_propose(p_business,p_branch) then
    raise exception 'identity coverage is outside actor scope' using errcode='42501';
  end if;
  select
    count(*)::bigint,
    count(*) filter(where s.client_id is not null)::bigint,
    count(*) filter(where current.effective_client_id is distinct from s.client_id)::bigint,
    count(distinct s.client_id) filter(where s.client_id is not null)::bigint,
    count(distinct coalesce(current.effective_client_id,s.client_id))
      filter(where s.client_id is not null)::bigint
  into v_total,v_identified,v_corrected,v_raw_customers,v_canonical_customers
  from public.sales s
  cross join lateral app.analytics_sale_class_v1(s) sc
  left join public.customer_identity_current_attribution_v111 current
    on current.business_id=s.business_id and current.source_client_id=s.client_id
  where s.business_id=p_business
    and (p_branch is null or s.branch_id=p_branch)
    and s.amount_cents>=0
    and s.counts_as_revenue
    and s.reversal_of is null
    and not sc.is_synthetic_client
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=s.business_id
        and reversal.reversal_of=s.id
    );
  return jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,
    'eligible_transaction_count',v_total,
    'identified_transaction_count',v_identified,
    'corrected_transaction_count',v_corrected,
    'raw_identified_customer_count',v_raw_customers,
    'canonical_identified_customer_count',v_canonical_customers,
    'identified_transaction_coverage',
      case when v_total=0 then null else round(v_identified::numeric/v_total,6) end
  );
end
$function$;

do $check5$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  from public.sales s
  left join public.customer_identity_current_attribution_v111 current
    on current.business_id=s.business_id and current.source_client_id=s.client_id
  where s.business_id=p_business
    and (p_branch is null or s.branch_id=p_branch)
    and s.amount_cents>=0
    and s.counts_as_revenue
    and s.reversal_of is null
    and not exists($lit$;
  v_new constant text := $lit$  from public.sales s
  cross join lateral app.analytics_sale_class_v1(s) sc
  left join public.customer_identity_current_attribution_v111 current
    on current.business_id=s.business_id and current.source_client_id=s.client_id
  where s.business_id=p_business
    and (p_branch is null or s.branch_id=p_branch)
    and s.amount_cents>=0
    and s.counts_as_revenue
    and s.reversal_of is null
    and not sc.is_synthetic_client
    and not exists($lit$;
begin
  select def into v_before from _v740_before where fn = 'get_customer_identity_coverage_v111';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_customer_identity_coverage_v111';
  if position(v_old in v_before) = 0 then
    raise exception 'v740/get_customer_identity_coverage_v111: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/get_customer_identity_coverage_v111: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check5$;

-- =============================================================================================
-- 6 · public.platform_generate_my_report_v89
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_generate_my_report_v89(p_business_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_ids uuid[];v_result jsonb;
begin
  if not app.v89_platform_can('reports','r') then
    raise exception 'platform reports access is required' using errcode='42501';
  end if;
  select coalesce(array_agg(distinct requested.id order by requested.id),'{}'::uuid[])
    into v_ids from unnest(coalesce(p_business_ids,'{}'::uuid[])) requested(id);
  if cardinality(v_ids)=0 or exists(select 1 from unnest(v_ids) id
    where not app.v89_business_in_role_scope(id)) then
    raise exception 'report contains an out-of-scope business' using errcode='42501';
  end if;
  select jsonb_build_object(
    'scope',jsonb_build_object('business_ids',to_jsonb(v_ids),
      'generated_at',now(),'currency','SGD'),
    'summary',jsonb_build_object(
      'business_count',cardinality(v_ids),
      'customer_count',(select count(*) from public.clients
        where business_id=any(v_ids) and not is_synthetic),
      'sales_count',(select count(*) from public.sales where business_id=any(v_ids)
        and reversal_of is null),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=any(v_ids)
          and sc.include_revenue and not sc.is_synthetic_client),0),
      'appointment_count',(select count(*) from public.appointments
        where business_id=any(v_ids)),
      'completed_appointments',(select count(*) from public.appointments
        where business_id=any(v_ids) and status='completed')
    ),
    'businesses',coalesce((select jsonb_agg(jsonb_build_object(
      'id',business.id,'name',business.name,'industry',business.industry,
      'customers',(select count(*) from public.clients
        where business_id=business.id and not is_synthetic),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=business.id
          and sc.include_revenue and not sc.is_synthetic_client),0)
    ) order by lower(business.name),business.id)
      from public.businesses business where business.id=any(v_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end
$function$;

do $check6$
declare v_before text; v_after text; v_expected text; v_step text;
  v_old1 constant text := $lit$      'customer_count',(select count(*) from public.clients where business_id=any(v_ids)),
      'sales_count',(select count(*) from public.sales where business_id=any(v_ids)
        and reversal_of is null),
      'revenue_cents',coalesce((select sum(amount_cents)::bigint
        from public.sales where business_id=any(v_ids)
          and reversal_of is null and counts_as_revenue),0),$lit$;
  v_new1 constant text := $lit$      'customer_count',(select count(*) from public.clients
        where business_id=any(v_ids) and not is_synthetic),
      'sales_count',(select count(*) from public.sales where business_id=any(v_ids)
        and reversal_of is null),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=any(v_ids)
          and sc.include_revenue and not sc.is_synthetic_client),0),$lit$;
  v_old2 constant text := $lit$      'customers',(select count(*) from public.clients where business_id=business.id),
      'revenue_cents',coalesce((select sum(amount_cents)::bigint
        from public.sales where business_id=business.id
          and reversal_of is null and counts_as_revenue),0)$lit$;
  v_new2 constant text := $lit$      'customers',(select count(*) from public.clients
        where business_id=business.id and not is_synthetic),
      'revenue_cents',coalesce((select sum(sale.amount_cents)::bigint
        from public.sales sale
        cross join lateral app.analytics_sale_class_v1(sale) sc
        where sale.business_id=business.id
          and sc.include_revenue and not sc.is_synthetic_client),0)$lit$;
begin
  select def into v_before from _v740_before where fn = 'platform_generate_my_report_v89';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_generate_my_report_v89';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v740/platform_generate_my_report_v89: anchor 1 not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v740/platform_generate_my_report_v89: anchor 2 not found in captured body';
  end if;
  v_expected := replace(replace(v_before, v_old1, v_new1), v_old2, v_new2);
  if v_after <> v_expected then
    raise exception 'v740/platform_generate_my_report_v89: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check6$;

-- =============================================================================================
-- 7 · public.platform_get_catalogue_affinity_v94
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_get_catalogue_affinity_v94(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_pairs jsonb:='[]'::jsonb;v_enabled boolean;v_from timestamptz;v_to timestamptz;
  v_transactions integer;v_customers integer;v_weeks integer;
  v_reasons jsonb:='[]'::jsonb;v_ready boolean;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_limit not between 1 and 100 or p_from is null or p_to is null
     or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_affinity_request' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  select catalogue_intelligence_enabled into v_enabled
  from public.business_platform_intelligence_settings_v94
  where business_id=p_business;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.id,sale.client_id,sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not sc.is_synthetic_client
      and not exists(select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id)
  )
  select count(*),count(distinct client_id),
    count(distinct date_trunc('week',occurred_at at time zone 'Asia/Singapore'))
  into v_transactions,v_customers,v_weeks from valid_sales;
  if not coalesce(v_enabled,false) then
    v_reasons:=v_reasons||jsonb_build_array('catalogue_intelligence_disabled');
  end if;
  if v_transactions<20 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_20_transactions_required');
  end if;
  if v_customers<10 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_10_customers_required');
  end if;
  if v_weeks<4 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_4_active_weeks_required');
  end if;
  v_ready:=jsonb_array_length(v_reasons)=0;
  if v_ready then
    with valid_sales as (
      select sale.id
      from public.sales sale
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id=p_business and sale.reversal_of is null
        and sale.occurred_at>=v_from and sale.occurred_at<v_to
        and (p_branch is null or sale.branch_id=p_branch)
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id)
    ), service_orders as (
      select item.ref_id service_id,count(distinct item.sale_id) orders
      from public.sale_items item join valid_sales sale on sale.id=item.sale_id
      where item.business_id=p_business and item.item_type='service'
        and item.ref_id is not null group by item.ref_id
    ), pairs as (
      select service_item.ref_id service_id,service.name service_name,
        product_item.ref_id product_id,product.name product_name,
        count(distinct service_item.sale_id) support_orders,
        max(service_orders.orders) sample_orders,
        sum(product_item.qty) product_units,
        sum(product_item.line_cents) paired_revenue_cents
      from public.sale_items service_item
      join public.sale_items product_item
        on product_item.business_id=service_item.business_id
        and product_item.sale_id=service_item.sale_id
        and product_item.item_type='retail'
      join valid_sales sale on sale.id=service_item.sale_id
      join public.services service
        on service.id=service_item.ref_id and service.business_id=p_business
      join public.products product
        on product.id=product_item.ref_id and product.business_id=p_business
      join service_orders on service_orders.service_id=service_item.ref_id
      where service_item.business_id=p_business
        and service_item.item_type='service'
      group by service_item.ref_id,service.name,product_item.ref_id,product.name
      having count(distinct service_item.sale_id)>=3
        and count(distinct service_item.sale_id)::numeric
          /nullif(max(service_orders.orders),0)>=0.10
      order by support_orders desc,service_item.ref_id,product_item.ref_id
      limit p_limit
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'service_id',service_id,'service_name',service_name,
      'product_id',product_id,'product_name',product_name,
      'support_orders',support_orders,'sample_orders',sample_orders,
      'confidence_pct',
        round(support_orders::numeric*100/nullif(sample_orders,0),2),
      'product_units',product_units,
      'paired_revenue_cents',paired_revenue_cents
    ) order by support_orders desc,service_id,product_id),'[]'::jsonb)
    into v_pairs from pairs;
  end if;
  return jsonb_build_object(
    'scope',jsonb_build_object('business_id',p_business,'branch_id',p_branch,
      'from',p_from,'to',p_to),
    'enabled',coalesce(v_enabled,false),
    'readiness',jsonb_build_object(
      'ready',v_ready,
      'thresholds',jsonb_build_object(
        'transactions',20,'customers',10,'active_weeks',4,
        'pair_support_orders',3,'pair_confidence_pct',10
      ),
      'observed',jsonb_build_object(
        'transactions',v_transactions,'customers',v_customers,
        'active_weeks',v_weeks
      ),
      'suppression_reasons',v_reasons
    ),
    'summary',jsonb_build_object('pair_count',jsonb_array_length(v_pairs)),
    'pairs',v_pairs
  );
end
$function$;

do $check7$
declare v_before text; v_after text; v_expected text;
  v_old1 constant text := $lit$  with valid_sales as (
    select sale.id,sale.client_id,sale.occurred_at
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id)
  )
  select count(*),count(distinct client_id),$lit$;
  v_new1 constant text := $lit$  with valid_sales as (
    select sale.id,sale.client_id,sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not sc.is_synthetic_client
      and not exists(select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id)
  )
  select count(*),count(distinct client_id),$lit$;
  v_old2 constant text := $lit$    with valid_sales as (
      select sale.id
      from public.sales sale
      where sale.business_id=p_business and sale.reversal_of is null
        and sale.occurred_at>=v_from and sale.occurred_at<v_to
        and (p_branch is null or sale.branch_id=p_branch)
        and not exists(select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id)
    ), service_orders as ($lit$;
  v_new2 constant text := $lit$    with valid_sales as (
      select sale.id
      from public.sales sale
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id=p_business and sale.reversal_of is null
        and sale.occurred_at>=v_from and sale.occurred_at<v_to
        and (p_branch is null or sale.branch_id=p_branch)
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id)
    ), service_orders as ($lit$;
begin
  select def into v_before from _v740_before where fn = 'platform_get_catalogue_affinity_v94';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_get_catalogue_affinity_v94';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v740/platform_get_catalogue_affinity_v94: anchor 1 not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v740/platform_get_catalogue_affinity_v94: anchor 2 not found in captured body';
  end if;
  v_expected := replace(replace(v_before, v_old1, v_new1), v_old2, v_new2);
  if v_after <> v_expected then
    raise exception 'v740/platform_get_catalogue_affinity_v94: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check7$;

-- =============================================================================================
-- 8 · public.get_revenue_summary
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_revenue_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_accrual bigint;
  v_cash bigint;
  v_sv_cash bigint;
  v_expenses bigint;
  v_unpaid bigint;
  v_collected bigint;
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_expenses_by_category jsonb;
  v_monthly jsonb;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from and p_to are required and p_from must be on or before p_to'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;

  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)'
      using errcode = '42501';
  end if;

  if p_branch is not null and not exists (
    select 1
      from public.branches b
     where b.id = p_branch
       and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business';
  end if;

  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;

  perform app.require_metric_module_scope_v145(p_business, p_branch, 'pnl');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'sales');
  perform app.require_metric_module_scope_v145(p_business, p_branch, 'expenses');

  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := (p_to + 1)::timestamp at time zone 'Asia/Singapore';

  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch)
     and not sc.is_synthetic_client;

  select coalesce(sum(p.amount_cents), 0)
    into v_cash
    from public.payments p
    join public.sales s
      on s.business_id = p.business_id
     and s.reversal_of is null
     and (
       s.id = p.sale_id
       or (
         p.sale_id is null
         and p.appointment_id is not null
         and s.appointment_id = p.appointment_id
       )
     )
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(t.reserved_cents), 0)
    into v_sv_cash
    from public.checkout_sv_tenders t
    join public.sales s
      on s.business_id = t.business_id
     and s.id = t.sale_id
     and s.reversal_of is null
   where t.business_id = p_business
     and t.status = 'consumed'
     and not exists (
       select 1 from public.checkout_sv_tender_reversals rv
        where rv.business_id = t.business_id and rv.tender_id = t.id)
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);
  v_cash := v_cash + v_sv_cash;

  select coalesce(sum(p.amount_cents), 0)
    into v_collected
    from public.payments p
   where p.business_id = p_business
     and p.method not in ('credit', 'gift_card')
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch);

  select coalesce(sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric)), 0)::bigint
    into v_expenses
    from public.expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  select coalesce(jsonb_object_agg(x.category, x.amount_cents order by x.category), '{}'::jsonb)
    into v_expenses_by_category
    from (
      select coalesce(nullif(btrim(e.category), ''), 'Uncategorised') as category,
             sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
      from public.expenses e
      where e.business_id = p_business
        and e.voided_at is null
        and e.occurred_on between p_from and p_to
        and (p_branch is null or e.branch_id = p_branch)
      group by coalesce(nullif(btrim(e.category), ''), 'Uncategorised')
    ) x;

  with months as (
    select generate_series(
      date_trunc('month', p_from::timestamp),
      date_trunc('month', p_to::timestamp),
      interval '1 month'
    )::date as month_start
  ), revenue as (
    select date_trunc('month', s.occurred_at at time zone 'Asia/Singapore')::date as month_start,
           sum(s.amount_cents)::bigint as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= v_from_ts
      and s.occurred_at < v_to_ts
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by 1
  ), expense as (
    select date_trunc('month', e.occurred_on::timestamp)::date as month_start,
           sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric))::bigint as amount_cents
    from public.expenses e
    where e.business_id = p_business
      and e.voided_at is null
      and e.occurred_on between p_from and p_to
      and (p_branch is null or e.branch_id = p_branch)
    group by 1
  )
  select coalesce(jsonb_object_agg(
    to_char(m.month_start, 'YYYY-MM'),
    jsonb_build_object(
      'revenue_accrual_cents', coalesce(r.amount_cents, 0),
      'expenses_cents', coalesce(e.amount_cents, 0)
    ) order by m.month_start
  ), '{}'::jsonb)
  into v_monthly
  from months m
  left join revenue r using (month_start)
  left join expense e using (month_start);

  return json_build_object(
    'from', p_from,
    'to', p_to,
    'branch_id', p_branch,
    'timezone', 'Asia/Singapore',
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents', v_cash,
    'cash_collected_cents', v_collected,
    'unpaid_balance_cents', v_unpaid,
    'expenses_cents', v_expenses,
    'expenses_scope', case when p_branch is null
      then 'all_business_expenses'
      else 'selected_branch_expenses_only_business_wide_overhead_excluded'
    end,
    'business_wide_overhead_excluded', p_branch is not null,
    'net_accrual_cents', v_accrual - v_expenses,
    'net_cash_cents', v_cash - v_expenses,
    'expenses_by_category', v_expenses_by_category,
    'monthly', v_monthly
  );
end $function$;

do $check8$
declare v_before text; v_after text; v_expected text;
  v_old1 constant text := $lit$  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);$lit$;
  v_new1 constant text := $lit$  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch)
     and not sc.is_synthetic_client;$lit$;
  v_old2 constant text := $lit$  ), revenue as (
    select date_trunc('month', s.occurred_at at time zone 'Asia/Singapore')::date as month_start,
           sum(s.amount_cents)::bigint as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= v_from_ts
      and s.occurred_at < v_to_ts
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ), expense as ($lit$;
  v_new2 constant text := $lit$  ), revenue as (
    select date_trunc('month', s.occurred_at at time zone 'Asia/Singapore')::date as month_start,
           sum(s.amount_cents)::bigint as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= v_from_ts
      and s.occurred_at < v_to_ts
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by 1
  ), expense as ($lit$;
begin
  select def into v_before from _v740_before where fn = 'get_revenue_summary';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_revenue_summary';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v740/get_revenue_summary: anchor 1 not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v740/get_revenue_summary: anchor 2 not found in captured body';
  end if;
  v_expected := replace(replace(v_before, v_old1, v_new1), v_old2, v_new2);
  if v_after <> v_expected then
    raise exception 'v740/get_revenue_summary: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check8$;

-- =============================================================================================
-- 9 · public.get_studio_sales_baseline_v145
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_studio_sales_baseline_v145(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_count bigint; v_average bigint;
begin
  if auth.uid() is null or not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform app.require_metric_module_scope_v145(p_business, null, 'sales');
  select count(*), coalesce(round(avg(sale.amount_cents)), 0)::bigint
    into v_count, v_average
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
   where sale.business_id = p_business
     and sale.reversal_of is null
     and sale.counts_as_revenue
     and sale.occurred_at >= now() - interval '30 days'
     and not sc.is_synthetic_client
     and not exists (
       select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
     );
  return jsonb_build_object(
    'available', true,
    'count30', v_count,
    'avg_bill_cents', coalesce(v_average, 0)
  );
end;
$function$;

do $check9$
declare v_before text; v_after text; v_expected text;
  v_old constant text := $lit$  select count(*), coalesce(round(avg(sale.amount_cents)), 0)::bigint
    into v_count, v_average
    from public.sales sale
   where sale.business_id = p_business
     and sale.reversal_of is null
     and sale.counts_as_revenue
     and sale.occurred_at >= now() - interval '30 days'
     and not exists ($lit$;
  v_new constant text := $lit$  select count(*), coalesce(round(avg(sale.amount_cents)), 0)::bigint
    into v_count, v_average
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
   where sale.business_id = p_business
     and sale.reversal_of is null
     and sale.counts_as_revenue
     and sale.occurred_at >= now() - interval '30 days'
     and not sc.is_synthetic_client
     and not exists ($lit$;
begin
  select def into v_before from _v740_before where fn = 'get_studio_sales_baseline_v145';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_studio_sales_baseline_v145';
  if position(v_old in v_before) = 0 then
    raise exception 'v740/get_studio_sales_baseline_v145: anchor not found in captured body';
  end if;
  v_expected := replace(v_before, v_old, v_new);
  if v_after <> v_expected then
    raise exception 'v740/get_studio_sales_baseline_v145: definition moved by more than the exclusion. %  %',
      E'\n--expected--\n' || v_expected, E'\n--actual--\n' || v_after;
  end if;
end
$check9$;

-- =============================================================================================
-- ACLs — restated exactly as they already are (CREATE OR REPLACE preserves grants; nothing here
-- widens or narrows anon/authenticated/service_role access).
-- =============================================================================================
revoke all on function public.get_reports_summary(uuid,date,date,uuid) from public;
grant execute on function public.get_reports_summary(uuid,date,date,uuid) to authenticated, service_role;

revoke all on function public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer) from public;
grant execute on function public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer) to authenticated, service_role;

revoke all on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) from public;
grant execute on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) to authenticated, service_role;

revoke all on function public.staff_customer_bucket_counts_v290(uuid,text,text,uuid[],uuid) from public;
grant execute on function public.staff_customer_bucket_counts_v290(uuid,text,text,uuid[],uuid) to authenticated, service_role;

revoke all on function public.get_customer_identity_coverage_v111(uuid,uuid) from public;
grant execute on function public.get_customer_identity_coverage_v111(uuid,uuid) to authenticated, service_role;

revoke all on function public.platform_generate_my_report_v89(uuid[]) from public;
grant execute on function public.platform_generate_my_report_v89(uuid[]) to authenticated, service_role;

revoke all on function public.platform_get_catalogue_affinity_v94(uuid,uuid,date,date,integer) from public;
grant execute on function public.platform_get_catalogue_affinity_v94(uuid,uuid,date,date,integer) to authenticated, service_role;

revoke all on function public.get_revenue_summary(uuid,date,date,uuid) from public;
grant execute on function public.get_revenue_summary(uuid,date,date,uuid) to authenticated, service_role;

revoke all on function public.get_studio_sales_baseline_v145(uuid) from public;
grant execute on function public.get_studio_sales_baseline_v145(uuid) to authenticated, service_role;

commit;
