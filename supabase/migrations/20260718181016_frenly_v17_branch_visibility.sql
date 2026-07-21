-- frenly_v17_branch_visibility — branch-scoped READ for a multi-tenant SaaS.
-- Owner/admin see all branches; employee sees only staff_branches-assigned branches.
-- Mechanism: RESTRICTIVE FOR SELECT policies (additional AND-term; never touches the
-- tenant-isolation policy, never affects writes) + an in-function guard on the
-- SECURITY DEFINER get_revenue_summary. Verified by Fable with rolled-back tests:
-- employee sees only assigned branch, cross-branch=0, cross-tenant=0, owner sees all.

create or replace function app.role_class(p_role text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_role = 'owner'                             then 'owner'
    when p_role = 'manager'                           then 'admin'
    when p_role in ('staff','frontdesk','bookkeeper') then 'employee'
    else 'employee'
  end;
$$;
comment on function app.role_class(text) is
  'v17: owner->owner, manager->admin, staff/frontdesk/bookkeeper->employee (unknown->employee).';

create or replace function app.can_see_branch(p_business uuid, p_branch uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null   then false
    when app.is_super_admin() then true
    else exists (
      select 1 from public.staff s
      where s.business_id = p_business and s.user_id = auth.uid()
        and ( app.role_class(s.role) in ('owner','admin')
           or ( p_branch is not null
                and exists (select 1 from public.staff_branches sb
                            where sb.business_id = p_business and sb.staff_id = s.id
                              and sb.branch_id = p_branch)) ) )
  end;
$$;
comment on function app.can_see_branch(uuid,uuid) is
  'v17 branch visibility. super-admin/owner/admin -> all branches (incl NULL). employee -> only staff_branches-assigned; NULL branch owner/admin only. Fail-closed for anon.';

grant execute on function app.role_class(text)          to authenticated;
grant execute on function app.can_see_branch(uuid,uuid) to authenticated;

drop policy if exists sales_branch_visibility on public.sales;
create policy sales_branch_visibility on public.sales
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists appointments_branch_visibility on public.appointments;
create policy appointments_branch_visibility on public.appointments
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists payments_branch_visibility on public.payments;
create policy payments_branch_visibility on public.payments
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists expenses_branch_visibility on public.expenses;
create policy expenses_branch_visibility on public.expenses
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists expense_recurrences_branch_visibility on public.expense_recurrences;
create policy expense_recurrences_branch_visibility on public.expense_recurrences
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists cash_drawer_sessions_branch_visibility on public.cash_drawer_sessions;
create policy cash_drawer_sessions_branch_visibility on public.cash_drawer_sessions
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

drop policy if exists cash_drawer_movements_branch_visibility on public.cash_drawer_movements;
create policy cash_drawer_movements_branch_visibility on public.cash_drawer_movements
  as restrictive for select to authenticated using (app.can_see_branch(business_id, branch_id));

create or replace function public.get_revenue_summary(
  p_business uuid, p_from date, p_to date, p_branch uuid default null::uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_accrual bigint; v_cash bigint; v_expenses bigint;
        v_unpaid bigint; v_collected bigint;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;
  select coalesce(sum(s.amount_cents), 0) into v_accrual
    from sales s
   where s.business_id = p_business and s.counts_as_revenue
     and s.occurred_at::date between p_from and p_to
     and (p_branch is null or s.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_cash
    from payments p
    join sales s on s.id = p.sale_id
       or (p.sale_id is null and p.appointment_id is not null and s.appointment_id = p.appointment_id)
   where p.business_id = p_business and s.counts_as_revenue
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_collected
    from payments p
   where p.business_id = p_business
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(b.balance_cents), 0) into v_unpaid
    from sale_balance b
   where b.business_id = p_business and b.counts_as_revenue and b.balance_cents > 0
     and b.occurred_at::date between p_from and p_to
     and (p_branch is null or b.branch_id = p_branch);
  select coalesce(sum(round(e.amount_cents * e.fx_rate_to_base)), 0) into v_expenses
    from expenses e
   where e.business_id = p_business and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);
  return json_build_object(
    'from', p_from, 'to', p_to, 'branch_id', p_branch,
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents',    v_cash,
    'cash_collected_cents',  v_collected,
    'unpaid_balance_cents',  v_unpaid,
    'expenses_cents',        v_expenses,
    'net_accrual_cents',     v_accrual - v_expenses,
    'net_cash_cents',        v_cash    - v_expenses);
end $$;

create or replace function public.super_admin_list_businesses()
returns table(business_id uuid, name text, industry text,
  branch_count int, staff_count int, client_count int,
  billable_seats int, subscription_status text, est_monthly_cents int)
language plpgsql security definer set search_path = public as $$
begin
  if not app.is_super_admin() then
    raise exception 'super admin only' using errcode = '42501';
  end if;
  insert into public.audit_log(business_id, actor, action, entity, detail)
    values (null, auth.uid(), 'READ', 'businesses',
            jsonb_build_object('fn','super_admin_list_businesses'));
  return query
    select b.id, b.name, b.industry,
           (select count(*)::int from public.branches br where br.business_id = b.id),
           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id),
           app.billable_seats(b.id),
           coalesce(sub.status, 'none'),
           coalesce(sub.base_price_cents
             + greatest(0, app.billable_seats(b.id) - sub.included_seats)
               * sub.per_seat_price_cents, 0)::int
    from public.businesses b
    left join public.subscriptions sub on sub.business_id = b.id
    order by b.name;
end;
$$;
comment on function public.super_admin_list_businesses() is
  'v17: platform super-admin roster of all tenants. is_super_admin() guarded; audited.';
grant execute on function public.super_admin_list_businesses() to authenticated;