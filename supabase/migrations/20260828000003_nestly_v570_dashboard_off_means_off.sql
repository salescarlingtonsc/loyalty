-- nestly_v570 -- "Dashboard: Off" actually turns the dashboard off.
--
-- THE DEFECT (owner, 2026-08-28): a staff member's module permissions were set to Dashboard =
-- Off (Record sale / Customers / Sales & refunds = Edit). The teammate still saw Dashboard in the
-- rail and the page rendered in full -- 30-day revenue SGD 380.00 and 16 valid visits -- to an
-- account the owner had explicitly denied it.
--
-- THE MODULE TOGGLE WAS ENFORCED NOWHERE. Three layers, none of them asking the authority:
--   * the router exempted it by name: `pageKey!=='dashboard'` in the module guard, with the
--     comment "dashboard/setup are always reachable" (v570's client half removes that);
--   * the rail listed it unconditionally (same);
--   * THIS function gated on app.has_perm(p_business,'view_sales') -- a ROLE permission that
--     every 'staff' role carries by definition (role_perms('staff') = view_sales, create_sales).
-- So the owner was offered an Off switch the product never honoured, on the one page that
-- aggregates the firm's money. Measured live before the fix: for the reported teammate,
-- app.can_module(business,'dashboard') = false while app.has_perm(business,'view_sales') = true.
--
-- THE FIX: the reader asks the module authority as well as the role. app.can_module ->
-- app.staff_module_mode_v94 keeps every existing account working: role='owner' returns the
-- platform mode (owners always pass), a staff row with modules IS NULL and no module_perms map
-- resolves 'rw' (inherit passes), and only an explicit denial resolves 'disabled'. One account in
-- production is affected today, which is the one the owner reported.
--
-- Scope note: this closes the dashboard, the surface that was reported and the one that carries
-- the money. Every OTHER module-gated reader keeps the gating it already had; the client half
-- makes the rail and the router honour the same answer so the denial is not merely cosmetic.
--
-- ROLLBACK: db/tests/v570_dashboard_off_means_off.sql

begin;

do $pre$
begin
  if position('app.can_module(p_business,''dashboard'')' in pg_get_functiondef('public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure)) > 0 then
    raise exception 'v570: the dashboard reader already asks the module authority';
  end if;
  if position('app.has_perm(p_business,''view_sales'')' in pg_get_functiondef('public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure)) = 0 then
    raise exception 'v570: expected the role-perm gate to patch -- re-derive from the live definition';
  end if;
end
$pre$;

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

-- ACL restated verbatim from the live proacl.
revoke all on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) from public, anon;
grant execute on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) to authenticated, service_role;

commit;
