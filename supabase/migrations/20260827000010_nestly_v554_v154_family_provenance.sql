-- nestly_v554 — the live v154 family gets repo provenance (TRUTH-003).
--
-- WHAT WAS WRONG. Production carries five functions the migration chain cannot build:
--   app.resolve_reporting_branch_scope_v154, app.reporting_scope_label_v154,
--   public.staff_list_customers_v154, public.get_dashboard_summary_v154,
--   public.preview_campaign_audience_v154
-- Zero migration files define them; the harness schema snapshot has none of them. A database
-- rebuilt from the repo therefore differs from production by five EXECUTE-granted functions,
-- and no test can exercise anything that touches them.
--
-- WHY CAPTURE RATHER THAN DROP. The reachability map (2026-08-27, read-only):
--   * the UI calls only the v155 successors; nothing in app.js, the platform console, the edge
--     functions or the writer registry names any v154 function;
--   * preview_campaign_audience_v154 calls staff_list_customers_v154, and the two app helpers
--     are called by the family itself (plus save_promotion_scope_v154, which the repo builds) —
--     PL/pgSQL resolves names at run time, so dropping any of them breaks callers silently;
--   * all five keep authenticated EXECUTE grants, so a client could still reach them, and
--     staff_list_customers_v154 was already corrected by nestly_v544 for exactly that reason.
-- Dropping callable surface is a behaviour change needing its own decision; provenance is not.
-- This migration makes a rebuild reproduce production, byte for byte, and nothing else.
--
-- The bodies below are pg_get_functiondef output from production 2026-08-27, verbatim. Do not
-- edit them here — a change to a v154 function is its own migration against the live body.
-- Grants are restated exactly as the live proacl shows.
--
-- ROLLBACK: db/tests/v554_v154_family_provenance.sql

begin;

-- ============================================================ app.resolve_reporting_branch_scope_v154
CREATE OR REPLACE FUNCTION app.resolve_reporting_branch_scope_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS TABLE(branch_id uuid, branch_name text, active boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_mode text := coalesce(nullif(btrim(p_scope_mode),''),'current');
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or not exists(
    select 1 from public.businesses business where business.id = p_business
  ) then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  if v_mode not in ('current','selected','all') then
    raise exception 'unsupported_reporting_branch_scope' using errcode='22023';
  end if;

  if v_mode = 'current' then
    if p_operational_branch is null then
      raise exception 'operational_branch_required_for_current_scope'
        using errcode='22023';
    end if;
    if not exists(
      select 1
      from public.branches branch
      where branch.id = p_operational_branch
        and branch.business_id = p_business
        and coalesce(branch.active,true)
    ) then
      raise exception 'foreign_or_inactive_branch_scope' using errcode='42501';
    end if;
    if not app.can_see_branch(p_business,p_operational_branch) then
      raise exception 'unauthorised_branch_scope' using errcode='42501';
    end if;
    return query
      select branch.id, branch.name, branch.active
      from public.branches branch
      where branch.id = p_operational_branch
        and branch.business_id = p_business
        and coalesce(branch.active,true);
    return;
  end if;

  if v_mode = 'selected' then
    with requested as (
      select distinct unnest(coalesce(p_branch_ids,array[]::uuid[])) as requested_branch_id
    )
    select count(*) into v_count from requested;
    if v_count = 0 then
      raise exception 'empty_selected_branch_scope' using errcode='22023';
    end if;
    if exists(
      with requested as (
        select distinct unnest(coalesce(p_branch_ids,array[]::uuid[])) as requested_branch_id
      )
      select 1
      from requested
      left join public.branches branch
        on branch.id = requested.requested_branch_id
       and branch.business_id = p_business
       and coalesce(branch.active,true)
      where branch.id is null
    ) then
      raise exception 'foreign_or_inactive_branch_scope' using errcode='42501';
    end if;
    if exists(
      with requested as (
        select distinct unnest(coalesce(p_branch_ids,array[]::uuid[])) as requested_branch_id
      )
      select 1
      from requested
      join public.branches branch
        on branch.id = requested.requested_branch_id
       and branch.business_id = p_business
      where not app.can_see_branch(p_business,branch.id)
    ) then
      raise exception 'unauthorised_branch_scope' using errcode='42501';
    end if;
    return query
      with requested as (
        select distinct unnest(coalesce(p_branch_ids,array[]::uuid[])) as requested_branch_id
      )
      select branch.id, branch.name, branch.active
      from requested
      join public.branches branch
        on branch.id = requested.requested_branch_id
       and branch.business_id = p_business
       and coalesce(branch.active,true)
      order by branch.name, branch.id;
    return;
  end if;

  return query
    select branch.id, branch.name, branch.active
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and app.can_see_branch(p_business,branch.id)
    order by branch.name, branch.id;
end
$function$;

-- grants restated verbatim from the live proacl: {postgres=X/postgres,authenticated=X/postgres}
revoke all on function app.resolve_reporting_branch_scope_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) from public, anon;
grant execute on function app.resolve_reporting_branch_scope_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to authenticated;

-- ============================================================ app.reporting_scope_label_v154
CREATE OR REPLACE FUNCTION app.reporting_scope_label_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with resolved as (
    select * from app.resolve_reporting_branch_scope_v154(
      p_business,p_scope_mode,p_branch_ids,p_operational_branch
    )
  )
  select case
    when coalesce(nullif(btrim(p_scope_mode),''),'current') = 'all'
      then case when count(*) = 1 then max(branch_name)
        else 'All accessible branches' end
    when count(*) = 1 then max(branch_name)
    else string_agg(branch_name,' + ' order by branch_name)
  end
  from resolved
$function$;

-- grants restated verbatim from the live proacl: {postgres=X/postgres,authenticated=X/postgres}
revoke all on function app.reporting_scope_label_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) from public, anon;
grant execute on function app.reporting_scope_label_v154(p_business uuid, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to authenticated;

-- ============================================================ public.staff_list_customers_v154
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

-- grants restated verbatim from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.staff_list_customers_v154(p_business uuid, p_search text, p_inactive_bucket text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid, p_limit integer, p_offset integer) from public, anon;
grant execute on function public.staff_list_customers_v154(p_business uuid, p_search text, p_inactive_bucket text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid, p_limit integer, p_offset integer) to authenticated;
grant execute on function public.staff_list_customers_v154(p_business uuid, p_search text, p_inactive_bucket text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid, p_limit integer, p_offset integer) to service_role;

-- ============================================================ public.get_dashboard_summary_v154
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
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and s.branch_id = any(v_scope_ids)
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
  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
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

-- grants restated verbatim from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.get_dashboard_summary_v154(p_business uuid, p_from date, p_to date, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) from public, anon;
grant execute on function public.get_dashboard_summary_v154(p_business uuid, p_from date, p_to date, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to authenticated;
grant execute on function public.get_dashboard_summary_v154(p_business uuid, p_from date, p_to date, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to service_role;

-- ============================================================ public.preview_campaign_audience_v154
CREATE OR REPLACE FUNCTION public.preview_campaign_audience_v154(p_business uuid, p_audience_key text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_scope_ids uuid[];
  v_label text;
  v_buckets text[] := case
    when p_audience_key in ('inactive_30_59','30_59') then array['30_59']
    when p_audience_key in ('inactive_60_89','60_89') then array['60_89']
    when p_audience_key in ('inactive_90_plus','90_plus') then array['90_plus']
    when p_audience_key in ('inactive_60_plus') then array['60_89','90_plus']
    when p_audience_key in ('never','never_visited') then array['never']
    else null
  end;
  v_customers jsonb;
  v_total integer;
  v_consent integer;
  v_bucket text;
  v_bucket_customers jsonb;
begin
  if v_buckets is null then
    raise exception 'unsupported_campaign_audience' using errcode='22023';
  end if;
  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v154(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_label := app.reporting_scope_label_v154(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  v_total := 0;
  v_consent := 0;
  foreach v_bucket in array v_buckets loop
    v_bucket_customers := public.staff_list_customers_v154(
      p_business,null,v_bucket,p_scope_mode,p_branch_ids,p_operational_branch,100,0
    );
    v_total := v_total + coalesce((v_bucket_customers->>'total')::integer,0);
    select v_consent + count(*)::integer into v_consent
    from jsonb_array_elements(coalesce(v_bucket_customers->'customers','[]'::jsonb)) customer
    where (customer->>'marketing_consent')::boolean is true;
  end loop;

  return jsonb_build_object(
    'status','ok',
    'audience_key',p_audience_key,
    'scope',jsonb_build_object(
      'mode',p_scope_mode,
      'label',v_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'wording',case when coalesce(p_scope_mode,'all')='all'
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

-- grants restated verbatim from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.preview_campaign_audience_v154(p_business uuid, p_audience_key text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) from public, anon;
grant execute on function public.preview_campaign_audience_v154(p_business uuid, p_audience_key text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to authenticated;
grant execute on function public.preview_campaign_audience_v154(p_business uuid, p_audience_key text, p_scope_mode text, p_branch_ids uuid[], p_operational_branch uuid) to service_role;


do $verify$
declare missing text;
begin
  select string_agg(fn, ', ') into missing from (values
    ('app.resolve_reporting_branch_scope_v154'), ('app.reporting_scope_label_v154'),
    ('public.staff_list_customers_v154'), ('public.get_dashboard_summary_v154'),
    ('public.preview_campaign_audience_v154')
  ) v(fn)
  where to_regprocedure(fn || '(' || case fn
      when 'public.get_dashboard_summary_v154' then 'uuid,date,date,text,uuid[],uuid'
      when 'public.preview_campaign_audience_v154' then 'uuid,text,text,uuid[],uuid'
      when 'public.staff_list_customers_v154' then 'uuid,text,text,text,uuid[],uuid,integer,integer'
      else 'uuid,text,uuid[],uuid' end || ')') is null;
  if missing is not null then
    raise exception 'v554: the repo still cannot build: %', missing;
  end if;
end
$verify$;

commit;
