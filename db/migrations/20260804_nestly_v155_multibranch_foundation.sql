-- NESTLY / PEEKAA V155 — SAFE MULTI-BRANCH FOUNDATION
--
-- Adds a canonical permission-checked reporting branch scope, selected/all
-- branch analytics readers, branch-scoped retention audiences, branch-scoped
-- promotion availability and a preparation-only campaign audience preview.
--
-- This migration deliberately does not change sale, revenue, ledger, reversal,
-- loyalty, credit, package, expense, P&L, appointment, billing, authentication,
-- tenant ownership or role-authority semantics.

begin;

create or replace function app.resolve_reporting_branch_scope_v155(
  p_business uuid,
  p_scope_mode text,
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid
)
returns table(branch_id uuid, branch_name text, active boolean)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
$$;

comment on function app.resolve_reporting_branch_scope_v155(uuid,text,uuid[],uuid) is
  'V155 canonical reporting branch-scope resolver. Current resolves exactly one operational branch; selected resolves a deduplicated non-empty authorised branch set; all resolves only active branches the current membership may see.';

create or replace function app.reporting_scope_label_v155(
  p_business uuid,
  p_scope_mode text,
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid
)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with resolved as (
    select * from app.resolve_reporting_branch_scope_v155(
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
$$;

create or replace function public.get_dashboard_summary_v155(
  p_business uuid,
  p_from date,
  p_to date,
  p_scope_mode text default 'current',
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
$$;

create or replace function public.staff_list_customers_v155(
  p_business uuid,
  p_search text default null,
  p_inactive_bucket text default null,
  p_scope_mode text default 'all',
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as points,
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
      'definition',case when v_scope_is_whole_business
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
$$;

create table if not exists public.promotion_branch_scopes_v155(
  promotion_id uuid not null
    references public.business_customer_content_v95(id) on delete cascade,
  business_id uuid not null
    references public.businesses(id) on delete cascade,
  branch_id uuid not null
    references public.branches(id) on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint promotion_branch_scopes_v155_unique unique(promotion_id,branch_id)
);

create index if not exists promotion_branch_scopes_v155_branch_idx
  on public.promotion_branch_scopes_v155(business_id,branch_id,promotion_id);

alter table public.promotion_branch_scopes_v155 enable row level security;

drop policy if exists promotion_branch_scopes_v155_staff_read
  on public.promotion_branch_scopes_v155;
create policy promotion_branch_scopes_v155_staff_read
  on public.promotion_branch_scopes_v155
  for select
  to authenticated
  using (
    app.is_super_admin()
    or app.can_see_branch(business_id,branch_id)
  );

revoke all on public.promotion_branch_scopes_v155 from public,anon,authenticated;
grant select on public.promotion_branch_scopes_v155 to authenticated;

create or replace function app.save_promotion_scope_v155(
  p_business uuid,
  p_promotion uuid,
  p_scope_mode text,
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_mode text := coalesce(nullif(btrim(p_scope_mode),''),'all');
  v_ids uuid[];
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if v_mode not in ('all','current','selected') then
    raise exception 'unsupported_promotion_scope' using errcode='22023';
  end if;
  if not exists(
    select 1 from public.business_customer_content_v95 content
    where content.id = p_promotion
      and content.business_id = p_business
      and content.content_type = 'offer'
  ) then
    raise exception 'promotion_not_found' using errcode='22023';
  end if;

  if v_mode = 'all' then
    delete from public.promotion_branch_scopes_v155 scope
    where scope.business_id = p_business
      and scope.promotion_id = p_promotion;
    perform set_config('app.v104_promotion_write','on',true);
    update public.business_customer_content_v95
    set branch_id = null,
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'branch_scope',jsonb_build_object('mode','all_branches')
        ),
        version = version + 1,
        updated_by = v_actor,
        updated_at = now()
    where id = p_promotion and business_id = p_business;
    perform set_config('app.v104_promotion_write','',true);
    return jsonb_build_object('mode','all','branch_ids','[]'::jsonb);
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,
    case when v_mode='current' then 'current' else 'selected' end,
    p_branch_ids,
    p_operational_branch
  ) scope;
  if cardinality(v_ids) = 0 then
    raise exception 'empty_selected_branch_scope' using errcode='22023';
  end if;

  delete from public.promotion_branch_scopes_v155 scope
  where scope.business_id = p_business
    and scope.promotion_id = p_promotion
    and not (scope.branch_id = any(v_ids));

  insert into public.promotion_branch_scopes_v155(
    promotion_id,business_id,branch_id,created_by
  )
  select p_promotion,p_business,branch_id,v_actor
  from unnest(v_ids) branch_id
  on conflict (promotion_id,branch_id) do nothing;

  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95
  set branch_id = null,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'branch_scope',jsonb_build_object(
          'mode','selected_branches',
          'branch_ids',to_jsonb(v_ids)
        )
      ),
      version = version + 1,
      updated_by = v_actor,
      updated_at = now()
  where id = p_promotion and business_id = p_business;
  perform set_config('app.v104_promotion_write','',true);

  return jsonb_build_object('mode','selected','branch_ids',to_jsonb(v_ids));
end
$$;

create or replace function app.promotion_available_at_branch_v155(
  p_promotion uuid,
  p_branch uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce((
    select case
      when p_branch is null then true
      when content.branch_id is not null then content.branch_id = p_branch
      when exists(
        select 1 from public.promotion_branch_scopes_v155 mapped
        where mapped.promotion_id = content.id
      ) then exists(
        select 1 from public.promotion_branch_scopes_v155 mapped
        where mapped.promotion_id = content.id
          and mapped.branch_id = p_branch
      )
      else true
    end
    from public.business_customer_content_v95 content
    where content.id = p_promotion
      and content.content_type = 'offer'
  ),false)
$$;

create or replace function public.assert_promotion_redeemable_at_branch_v155(
  p_business uuid,
  p_promotion uuid,
  p_branch uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_content public.business_customer_content_v95%rowtype;
begin
  if auth.uid() is null or not app.has_perm(p_business,'create_sales') then
    raise exception 'sales access required' using errcode='42501';
  end if;
  if p_branch is null or not app.can_see_branch(p_business,p_branch) then
    raise exception 'unauthorised_branch_scope' using errcode='42501';
  end if;
  select * into v_content
  from public.business_customer_content_v95 content
  where content.id = p_promotion
    and content.business_id = p_business
    and content.content_type = 'offer'
  for share;
  if not found
     or not v_content.active
     or (v_content.starts_at is not null and v_content.starts_at > now())
     or v_content.ends_at <= now() then
    raise exception 'promotion_not_available' using errcode='22023';
  end if;
  if not app.promotion_available_at_branch_v155(p_promotion,p_branch) then
    raise exception 'This promotion is not available at the selected branch.'
      using errcode='42501';
  end if;
  return jsonb_build_object(
    'status','ok',
    'promotion_id',p_promotion,
    'business_id',p_business,
    'branch_id',p_branch
  );
end
$$;

create or replace function public.business_get_promotion_editor_v155(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_base jsonb;
  v_items jsonb;
begin
  v_base := public.business_get_promotion_editor_v104(p_business);
  with items as (
    select value item
    from jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb))
  )
  select coalesce(jsonb_agg(
    item || jsonb_build_object(
      'branch_scope',case
        when exists(
          select 1 from public.promotion_branch_scopes_v155 mapped
          where mapped.promotion_id = (item->>'id')::uuid
        ) then jsonb_build_object(
          'mode','selected_branches',
          'branch_ids',(
            select coalesce(jsonb_agg(mapped.branch_id order by branch.name),'[]'::jsonb)
            from public.promotion_branch_scopes_v155 mapped
            join public.branches branch on branch.id = mapped.branch_id
            where mapped.promotion_id = (item->>'id')::uuid
          ),
          'branch_names',(
            select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb)
            from public.promotion_branch_scopes_v155 mapped
            join public.branches branch on branch.id = mapped.branch_id
            where mapped.promotion_id = (item->>'id')::uuid
          )
        )
        else jsonb_build_object('mode','all_branches','branch_ids','[]'::jsonb,'branch_names','[]'::jsonb)
      end
    )
  ),'[]'::jsonb)
  into v_items
  from items;
  return jsonb_set(v_base,'{items}',v_items,true);
end
$$;

create or replace function public.business_create_promotion_draft_v155(
  p_business uuid,
  p_promotion_id uuid,
  p_attempt_key uuid,
  p_scope_mode text,
  p_branch_ids uuid[],
  p_operational_branch uuid,
  p_name text,
  p_tagline text,
  p_description text,
  p_terms text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_display_order integer,
  p_cta_kind text,
  p_cta_label text,
  p_offer_facts text,
  p_occasion text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_result jsonb;
  v_scope jsonb;
begin
  v_result := public.business_create_promotion_draft_v104(
    p_business,p_promotion_id,p_attempt_key,null,p_name,p_tagline,
    p_description,p_terms,p_starts_at,p_ends_at,p_display_order,p_cta_kind,
    p_cta_label,p_offer_facts,p_occasion
  );
  v_scope := app.save_promotion_scope_v155(
    p_business,p_promotion_id,p_scope_mode,p_branch_ids,p_operational_branch
  );
  return v_result || jsonb_build_object('branch_scope',v_scope);
end
$$;

create or replace function public.business_finalize_promotion_v155(
  p_business uuid,
  p_promotion_id uuid,
  p_scope_mode text,
  p_branch_ids uuid[],
  p_operational_branch uuid,
  p_name text,
  p_tagline text,
  p_description text,
  p_terms text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_display_order integer,
  p_cta_kind text,
  p_cta_label text,
  p_offer_facts text,
  p_occasion text,
  p_publish boolean,
  p_object_path text,
  p_mime_type text,
  p_width_px integer,
  p_height_px integer,
  p_alt_en text,
  p_expected_content_version bigint,
  p_expected_copy_version bigint,
  p_expected_target_media_version bigint,
  p_attempt_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_result jsonb;
  v_scope jsonb;
begin
  v_result := public.business_finalize_promotion_v104(
    p_business,p_promotion_id,null,p_name,p_tagline,p_description,p_terms,
    p_starts_at,p_ends_at,p_display_order,p_cta_kind,p_cta_label,
    p_offer_facts,p_occasion,p_publish,p_object_path,p_mime_type,
    p_width_px,p_height_px,p_alt_en,p_expected_content_version,
    p_expected_copy_version,p_expected_target_media_version,p_attempt_key
  );
  v_scope := app.save_promotion_scope_v155(
    p_business,p_promotion_id,p_scope_mode,p_branch_ids,p_operational_branch
  );
  return v_result || jsonb_build_object('branch_scope',v_scope);
end
$$;

create or replace function public.customer_get_promotions_v155(
  p_business uuid,
  p_branch uuid default null::uuid,
  p_locale text default 'en'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_locale not in ('en','zh-CN') then
    raise exception 'valid_promotion_reader_context_required' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id = p_branch
      and branch.business_id = p_business
      and coalesce(branch.active,true)
  ) then
    raise exception 'branch_not_available' using errcode='42501';
  end if;

  v_identity := app.v31_current_identity();
  if not exists(
    select 1
    from public.customer_links link
    where link.identity_id = v_identity
      and link.auth_user_id = v_actor
      and link.business_id = p_business
      and link.state = 'verified'
  ) then
    raise exception 'verified_customer_link_required' using errcode='42501';
  end if;

  with visible as (
    select
      content.id,content.display_order,content.starts_at,content.ends_at,
      content.metadata,content.updated_at,
      coalesce(copy.name,english.name,'Offer') name,
      coalesce(copy.tagline,english.tagline) tagline,
      coalesce(copy.description,english.description) description,
      coalesce(copy.terms,english.terms) terms,
      media.url image_url,media.image_alt,
      branches.names branch_names
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id = p_business
     and copy.entity_type = 'offer'
     and copy.entity_id = content.id
     and copy.locale = p_locale
    left join public.business_localized_copy_v95 english
      on english.business_id = p_business
     and english.entity_type = 'offer'
     and english.entity_id = content.id
     and english.locale = 'en'
    left join lateral(
      select app.v95_public_media_url(asset.object_path) url,
        case when p_locale='zh-CN'
          then coalesce(asset.alt_zh_cn,asset.alt_en)
          else asset.alt_en
        end image_alt
      from public.business_media_assets_v95 asset
      where asset.business_id = p_business
        and asset.asset_kind = 'offer'
        and asset.entity_id = content.id
        and asset.customer_visible
        and asset.branch_id is null
      order by asset.updated_at desc,asset.id
      limit 1
    ) media on true
    left join lateral(
      select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb) names
      from public.promotion_branch_scopes_v155 mapped
      join public.branches branch on branch.id = mapped.branch_id
      where mapped.promotion_id = content.id
    ) branches on true
    where content.business_id = p_business
      and content.content_type = 'offer'
      and content.active
      and content.branch_id is null
      and app.promotion_available_at_branch_v155(content.id,p_branch)
      and (content.starts_at is null or content.starts_at <= now())
      and content.ends_at > now()
      and media.url is not null
    order by content.display_order,content.starts_at desc nulls last,
      content.updated_at desc,content.id
    limit 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',visible.id,
    'name',visible.name,
    'tagline',visible.tagline,
    'description',visible.description,
    'terms',visible.terms,
    'image_url',visible.image_url,
    'image_alt',visible.image_alt,
    'starts_at',visible.starts_at,
    'ends_at',visible.ends_at,
    'display_order',visible.display_order,
    'metadata',visible.metadata,
    'branch_names',visible.branch_names,
    'availability_label',case when jsonb_array_length(visible.branch_names)>0
      then 'Available at ' || (
        select string_agg(value,' and ' order by value)
        from jsonb_array_elements_text(visible.branch_names) value
      )
      else 'Available at all branches' end
  ) order by visible.display_order,visible.starts_at desc nulls last,
      visible.updated_at desc,visible.id),'[]'::jsonb)
  into v_items
  from visible;

  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'locale',p_locale,
    'items',v_items,
    'limit',2
  );
end
$$;

create or replace function public.preview_campaign_audience_v155(
  p_business uuid,
  p_audience_key text,
  p_scope_mode text default 'all',
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null::uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
$$;

revoke all on function app.resolve_reporting_branch_scope_v155(uuid,text,uuid[],uuid)
  from public,anon,authenticated;
revoke all on function app.reporting_scope_label_v155(uuid,text,uuid[],uuid)
  from public,anon,authenticated;
revoke all on function app.save_promotion_scope_v155(uuid,uuid,text,uuid[],uuid)
  from public,anon,authenticated;
revoke all on function app.promotion_available_at_branch_v155(uuid,uuid)
  from public,anon,authenticated;
grant execute on function app.resolve_reporting_branch_scope_v155(uuid,text,uuid[],uuid)
  to authenticated;
grant execute on function app.reporting_scope_label_v155(uuid,text,uuid[],uuid)
  to authenticated;
grant execute on function app.promotion_available_at_branch_v155(uuid,uuid)
  to authenticated;

revoke all on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)
  from public,anon,authenticated;
revoke all on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)
  from public,anon,authenticated;
revoke all on function public.assert_promotion_redeemable_at_branch_v155(uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.business_get_promotion_editor_v155(uuid)
  from public,anon,authenticated;
revoke all on function public.business_create_promotion_draft_v155(
  uuid,uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text
) from public,anon,authenticated;
revoke all on function public.business_finalize_promotion_v155(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean,text,text,integer,integer,text,bigint,bigint,bigint,uuid
) from public,anon,authenticated;
revoke all on function public.customer_get_promotions_v155(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.preview_campaign_audience_v155(uuid,text,text,uuid[],uuid)
  from public,anon,authenticated;

grant execute on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)
  to authenticated;
grant execute on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)
  to authenticated;
grant execute on function public.assert_promotion_redeemable_at_branch_v155(uuid,uuid,uuid)
  to authenticated;
grant execute on function public.business_get_promotion_editor_v155(uuid)
  to authenticated;
grant execute on function public.business_create_promotion_draft_v155(
  uuid,uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text
) to authenticated;
grant execute on function public.business_finalize_promotion_v155(
  uuid,uuid,text,uuid[],uuid,text,text,text,text,timestamptz,timestamptz,integer,text,text,text,text,boolean,text,text,integer,integer,text,bigint,bigint,bigint,uuid
) to authenticated;
grant execute on function public.customer_get_promotions_v155(uuid,uuid,text)
  to authenticated;
grant execute on function public.preview_campaign_audience_v155(uuid,text,text,uuid[],uuid)
  to authenticated;

commit;
