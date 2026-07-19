-- Server-side reporting aggregates. Raw export rows remain paged by the client.
-- The functions are SECURITY INVOKER so table RLS remains an independent boundary;
-- explicit guards make cross-tenant and unassigned-branch calls fail loudly.

begin;

create index if not exists sales_business_branch_occurred_idx
  on public.sales (business_id, branch_id, occurred_at);
create index if not exists clients_business_created_idx
  on public.clients (business_id, created_at);
create index if not exists points_ledger_business_created_idx
  on public.points_ledger (business_id, created_at);
create index if not exists gift_cards_business_status_idx
  on public.gift_cards (business_id, status);
create index if not exists memberships_business_status_idx
  on public.memberships (business_id, status);

create or replace function public.get_dashboard_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
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

  select jsonb_build_object(
    'visits', count(*) filter (where s.counts_as_visit),
    'revenue_cents', coalesce(sum(s.amount_cents) filter (where s.counts_as_revenue), 0),
    'unique_customers', count(distinct s.client_id) filter (where s.client_id is not null)
  )
  into v_kpis
  from public.sales s
  where s.business_id = p_business
    and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
    and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    and (p_branch is null or s.branch_id = p_branch);

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ),
    'points_issued', (
      select coalesce(sum(pl.points), 0) from public.points_ledger pl
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ),
    'credit_liability_cents', (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      where cb.business_id = p_business
    )
  );

  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays
  from generate_series(1, 7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) w using (day_no);

  select coalesce(
    jsonb_agg(jsonb_build_object('day', r.sale_day, 'amount_cents', r.amount_cents)
              order by r.sale_day),
    '[]'::jsonb)
  into v_revenue_by_day
  from (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) r;

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
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age(current_date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age(current_date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age(current_date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age(current_date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age(current_date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday', v_weekdays,
    'revenue_by_day', v_revenue_by_day,
    'gender_counts', v_gender,
    'age_counts', v_age
  );
end;
$$;

create or replace function public.get_reports_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module(p_business, 'reports') then
    raise exception 'you do not have permission to view reports for this business'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
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

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
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
  ) x;

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

  select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
  into v_points
  from (
    select pl.entry_type, sum(pl.points) as points
    from public.points_ledger pl
    where pl.business_id = p_business
      and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    group by pl.entry_type
  ) x;

  select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
  into v_credit_liability
  from public.client_credit_balance cb
  where cb.business_id = p_business;

  select coalesce(sum(gc.balance_cents) filter (where gc.status = 'active'), 0)
  into v_gift_card_liability
  from public.gift_cards gc
  where gc.business_id = p_business;

  select count(*) filter (where m.status = 'active')
  into v_active_memberships
  from public.memberships m
  where m.business_id = p_business;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships
  );
end;
$$;

-- Verified applied v17 helper signatures:
--   app.has_perm(uuid,text), app.can_module(uuid,text),
--   app.can_see_branch(uuid,uuid). Reassert least-privilege EXECUTE because
--   PostgreSQL grants EXECUTE on new functions to PUBLIC by default.
revoke execute on function app.has_perm(uuid, text) from public, anon;
revoke execute on function app.can_module(uuid, text) from public, anon;
revoke execute on function app.can_see_branch(uuid, uuid) from public, anon;
grant execute on function app.has_perm(uuid, text) to authenticated;
grant execute on function app.can_module(uuid, text) to authenticated;
grant execute on function app.can_see_branch(uuid, uuid) to authenticated;

revoke all on function public.get_dashboard_summary(uuid, date, date, uuid)
  from public, anon;
revoke all on function public.get_reports_summary(uuid, date, date, uuid)
  from public, anon;
grant execute on function public.get_dashboard_summary(uuid, date, date, uuid)
  to authenticated;
grant execute on function public.get_reports_summary(uuid, date, date, uuid)
  to authenticated;

commit;
