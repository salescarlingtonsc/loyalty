-- nestly_v865 — "visits" means ONE thing on the Dashboard.
--
-- THE DEFECT. public.get_dashboard_summary_v155 answered the SAME question two different ways in
-- the SAME return value, and the app draws both of them on one screen:
--
--   * the Visits KPI tile counts DEDUPLICATED customer visit-days. It builds scoped_sales (which
--     drops synthetic-client rows via app.analytics_sale_class_v1), narrows to valid, unreversed,
--     counts_as_visit originals, then collapses an identified customer's same-day rows into ONE
--     visit-day through the one visit-day authority app.ci_visit_day_v699 (nestly_v699/v714).
--     A split bill is one visit. Walk-ins carry no identity to dedupe by, so each still counts.
--
--   * the visits_by_weekday chart directly beneath it counted RAW SALE ROWS. It re-derived its own
--     valid_visits CTE straight off public.sales, WITHOUT the synthetic-client filter, and did
--     count(*) per weekday. Every split bill and every extra same-day sale was another "visit".
--
-- On every real tenant with any same-day repeat activity the tile and the chart under it disagree
-- by 2x-5x (measured against production, all branches, 2023-01-01..2027-01-01, via the live RPC
-- called as each tenant's own owner):
--
--     Cubbly SPA            tile 39   chart 75   [21,10,12,5,5,12,10]
--     ELAN Wellness         tile 17   chart 29   [12, 6, 1,9,1, 0, 0]
--     Hougang ABC           tile 16   chart 29   [ 5, 2, 9,5,5, 0, 3]
--     QA Kaya Toast         tile  7   chart 23   [ 3, 6, 1,0,0,10, 3]
--     QA Kopi Lab (Bedok)   tile  4   chart 20   [ 1, 1, 0,0,0,13, 5]
--
-- THE FIX. One visit definition, used everywhere. The deduplicated visit-day is the canonical one
-- — it is already what the Visits tile, unique_customers and repeat_customers use, and what the
-- owner brief cites — so the chart is rewritten to ask exactly the tile's question, broken out by
-- day rather than replaced by a second definition:
--
--   1. the weekday block now builds off the same scoped_sales shape, so `not sc.is_synthetic_client`
--      applies here too. That inconsistency was a second, independent divergence: the tile excluded
--      synthetic-client rows and the chart included them.
--   2. identified customers are deduplicated by (client_id, app.ci_visit_day_v699(occurred_at)),
--      the same authority the tile uses.
--   3. walk-ins (client_id is null) cannot be deduplicated by identity, so each such sale still
--      counts on its own — precisely the fallback the tile takes. That is what makes the chart
--      total equal the tile EXACTLY rather than approximately.
--   4. the weekday bucket is taken from the VISIT-DAY, not from the raw timestamp. A visit-day is
--      an SGT calendar day by construction, so the day a visit is filed under and the day it is
--      charted on can never drift apart.
--
-- This is the same shape app.v179_business_insights' weekday block already carries (nestly_v715);
-- v155 is the reader that was left behind. Nothing else in the function changes: the KPI block,
-- points_issued, revenue_by_day, the gender/age cohorts, the permission gates and the returned
-- scope descriptors are byte-for-byte what v828 left.
--
-- AFTER, on the same production rows (sum of the array equals the tile, tenant by tenant):
--     Cubbly SPA            tile 39   chart 39   [5,6,6,5,3,8,6]
--     ELAN Wellness         tile 17   chart 17   [5,3,1,7,1,0,0]
--     Hougang ABC           tile 16   chart 16   [4,2,3,2,3,0,2]
--     QA Kaya Toast         tile  7   chart  7   [1,2,1,0,0,1,2]
--     QA Kopi Lab (Bedok)   tile  4   chart  4   [1,1,0,0,0,1,1]
--
-- NOT IN THIS MIGRATION (reported, deliberately not touched here). Three other readers still count
-- raw sale rows as visits and will each need their own change:
-- public.get_dashboard_summary(uuid,date,date,uuid) — the Daily report, whose weekday block has the
-- synthetic filter but still does count(*); public.get_ci_branch_comparison_v1 and
-- public.get_ci_visit_rhythm_v1 (count(*) filter (where is_visit)); public.get_ci_staff_rebooking_v1
-- (count(*) per staff). public.get_dashboard_summary_v154 carries the identical defect but the app
-- no longer calls it.

begin;

create or replace function public.get_dashboard_summary_v155(p_business uuid, p_from date, p_to date, p_scope_mode text default 'current'::text, p_branch_ids uuid[] default array[]::uuid[], p_operational_branch uuid default null::uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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

  -- nestly_v865: the weekday chart is the SAME visits number as the tile above it, broken out by
  -- day. It used to be a second, contradictory definition: it re-derived its own valid_visits CTE
  -- straight off public.sales -- WITHOUT the synthetic-client filter the KPI block applies -- and
  -- then counted RAW SALE ROWS, so a split bill or any same-day repeat became another "visit" in
  -- the chart while staying one visit in the tile. Now it builds off the same scoped_sales shape,
  -- deduplicates identified customers by (client_id, visit-day) through the one visit-day
  -- authority app.ci_visit_day_v699, and lets each walk-in (client_id is null) count on its own --
  -- the tile's exact fallback, and what makes sum(chart) equal the tile rather than approximate
  -- it. The bucket is taken from the visit-day, not the raw timestamp, so the day a visit is filed
  -- under and the day it is charted on cannot drift apart. Same shape as the weekday block in
  -- app.v179_business_insights (nestly_v715); this reader was the one left behind.
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
  )
  select coalesce(jsonb_agg(coalesce(w.visits,0) order by d.day_no),'[]'::jsonb)
  into v_weekdays
  from generate_series(1,7) d(day_no)
  left join (
    select extract(isodow from app.ci_visit_day_v699(s.occurred_at))::int as day_no,
           count(distinct (s.client_id, app.ci_visit_day_v699(s.occurred_at)))
             filter (where s.client_id is not null)
           + count(*) filter (where s.client_id is null) as visits
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

-- Grants restated verbatim from the live ACL this function carries today
-- ({postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}). No anon, no public.
revoke all on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid)
  from public, anon;
grant execute on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid)
  to authenticated, service_role;

comment on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid) is
  'nestly_v865. The Dashboard summary. One visit definition throughout: the Visits tile, '
  'repeat_customers, unique_customers AND visits_by_weekday all count deduplicated customer '
  'visit-days (app.ci_visit_day_v699, nestly_v699/v714), with walk-ins counting per sale because '
  'they carry no identity to deduplicate by. sum(visits_by_weekday) equals visits exactly. Before '
  'v865 the weekday chart counted raw sale rows off an unfiltered CTE and disagreed with the tile '
  'directly above it by 2x-5x on real tenants.';

do $verify$
declare
  v_def text;
begin
  select pg_get_functiondef(
    'public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure)
    into v_def;

  -- The weekday chart must deduplicate by visit-day, not count rows.
  if position('count(distinct (s.client_id, app.ci_visit_day_v699(s.occurred_at)))' in v_def) = 0 then
    raise exception 'nestly_v865: the weekday chart is still counting raw sale rows'
      using errcode='XX001';
  end if;

  -- Walk-ins must still count one apiece, or the chart total stops equalling the tile.
  if position('+ count(*) filter (where s.client_id is null) as visits' in v_def) = 0 then
    raise exception 'nestly_v865: the weekday chart no longer counts walk-in sales'
      using errcode='XX001';
  end if;

  -- Both CTE chains -- the KPI block and the weekday block -- must apply the same
  -- synthetic-client filter. Two occurrences, no more and no fewer.
  if (length(v_def) - length(replace(v_def, 'not sc.is_synthetic_client', ''))) /
       length('not sc.is_synthetic_client') <> 2 then
    raise exception 'nestly_v865: the KPI block and the weekday block do not both filter synthetic clients'
      using errcode='XX001';
  end if;

  -- The weekday bucket must come from the visit-day, never from the raw timestamp.
  if position('extract(isodow from app.ci_visit_day_v699(s.occurred_at))' in v_def) = 0
     or position('extract(isodow from s.occurred_at at time zone' in v_def) > 0 then
    raise exception 'nestly_v865: the weekday bucket is not taken from the visit-day'
      using errcode='XX001';
  end if;
end
$verify$;

commit;
