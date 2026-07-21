create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  branch_id      uuid,
  sale_id        uuid,
  appointment_id uuid,
  client_id      uuid,
  staff_id       uuid,
  method         text not null check (method in
                   ('cash','card','paynow','bank_transfer','credit','gift_card','other')),
  kind           text not null default 'payment'
                   check (kind in ('payment','deposit','no_show_fee','refund')),
  amount_cents   integer not null check (amount_cents <> 0),
  check ((kind = 'refund' and amount_cents < 0) or (kind <> 'refund' and amount_cents > 0)),
  occurred_at    timestamptz not null default now(),
  reference      text,
  note           text,
  idempotency_key text,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);
alter table public.payments
  add constraint payments_id_business_key unique (id, business_id),
  add constraint payments_sale_same_tenant   foreign key (sale_id, business_id)
      references public.sales(id, business_id),
  add constraint payments_appt_same_tenant   foreign key (appointment_id, business_id)
      references public.appointments(id, business_id),
  add constraint payments_staff_same_tenant  foreign key (staff_id, business_id)
      references public.staff(id, business_id),
  add constraint payments_client_same_tenant foreign key (client_id, business_id)
      references public.clients(id, business_id),
  add constraint payments_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);
create unique index payments_idempotency
  on public.payments (business_id, idempotency_key)
  where idempotency_key is not null;
create index payments_sale        on public.payments (sale_id) where sale_id is not null;
create index payments_appointment on public.payments (appointment_id) where appointment_id is not null;
create index payments_branch_time on public.payments (branch_id, occurred_at);
create index payments_business_time on public.payments (business_id, occurred_at);
create index payments_client      on public.payments (client_id, occurred_at) where client_id is not null;
alter table public.payments enable row level security;
create policy payments_select on public.payments for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
create policy payments_insert on public.payments for insert to authenticated
  with check (app.has_perm(business_id, 'create_sales')
              and (kind <> 'refund' or app.has_perm(business_id, 'refund_sales')));
revoke all on public.payments from anon;
revoke update, delete, truncate on public.payments from authenticated;
grant select, insert on public.payments to authenticated;
create or replace function app.forbid_mutation()
returns trigger language plpgsql set search_path = public as $$
begin
  raise exception '% is an append-only ledger: % is not permitted. Post a reversing row instead.',
    tg_table_name, tg_op;
end $$;
create trigger trg_payments_append_only
  before update or delete on public.payments
  for each row execute function app.forbid_mutation();
create trigger trg_payments_audit
  after insert on public.payments
  for each row execute function app.audit();
create trigger trg_payments_default_branch
  before insert on public.payments
  for each row execute function app.set_row_branch();
create view public.sale_balance
with (security_invoker = on) as
select s.id                                            as sale_id,
       s.business_id,
       s.branch_id,
       s.client_id,
       s.appointment_id,
       s.kind,
       s.counts_as_revenue,
       s.amount_cents,
       s.occurred_at,
       coalesce(sum(p.amount_cents), 0)::integer       as paid_cents,
       (s.amount_cents - coalesce(sum(p.amount_cents), 0))::integer as balance_cents,
       case
         when coalesce(sum(p.amount_cents), 0) <= 0             then 'unpaid'
         when coalesce(sum(p.amount_cents), 0) <  s.amount_cents then 'partial'
         when coalesce(sum(p.amount_cents), 0) =  s.amount_cents then 'paid'
         else 'overpaid'
       end                                             as payment_status
from public.sales s
left join public.payments p
  on  p.sale_id = s.id
   or (p.sale_id is null
       and s.appointment_id is not null
       and p.appointment_id = s.appointment_id)
where app.has_perm(s.business_id, 'view_finance')
group by s.id, s.business_id, s.branch_id, s.client_id, s.appointment_id,
         s.kind, s.counts_as_revenue, s.amount_cents, s.occurred_at;
revoke all on public.sale_balance from anon;
grant select on public.sale_balance to authenticated;
create or replace function public.record_payment(
  p_business        uuid,
  p_method          text,
  p_amount_cents    integer,
  p_sale            uuid    default null,
  p_appointment     uuid    default null,
  p_client          uuid    default null,
  p_staff           uuid    default null,
  p_kind            text    default 'payment',
  p_branch          uuid    default null,
  p_reference       text    default null,
  p_note            text    default null,
  p_idempotency_key text    default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row payments; v_branch uuid; v_client uuid;
begin
  if p_kind = 'refund' then
    if not app.has_perm(p_business, 'refund_sales') then
      raise exception 'you do not have permission to refund in this business (refund_sales)';
    end if;
  elsif not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to take a payment in this business (create_sales)';
  end if;
  if p_sale is null and p_appointment is null then
    raise exception 'a payment must reference a sale or an appointment';
  end if;
  if p_sale is not null and not exists (
       select 1 from sales where id = p_sale and business_id = p_business) then
    raise exception 'sale does not belong to this business';
  end if;
  if p_appointment is not null and not exists (
       select 1 from appointments where id = p_appointment and business_id = p_business) then
    raise exception 'appointment does not belong to this business';
  end if;
  if p_staff is not null and not exists (
       select 1 from staff where id = p_staff and business_id = p_business) then
    raise exception 'staff does not belong to this business';
  end if;
  if p_kind = 'refund' then
    p_amount_cents := -abs(p_amount_cents);
  else
    p_amount_cents := abs(p_amount_cents);
  end if;
  if p_amount_cents = 0 then raise exception 'amount must be non-zero'; end if;
  v_branch := coalesce(p_branch,
                       (select branch_id from sales where id = p_sale),
                       (select branch_id from appointments where id = p_appointment));
  v_client := coalesce(p_client,
                       (select client_id from sales where id = p_sale),
                       (select client_id from appointments where id = p_appointment));
  insert into payments (business_id, branch_id, sale_id, appointment_id, client_id,
                        staff_id, method, kind, amount_cents, reference, note,
                        idempotency_key)
  values (p_business, v_branch, p_sale, p_appointment, v_client,
          p_staff, p_method, p_kind, p_amount_cents, p_reference, p_note,
          p_idempotency_key)
  on conflict (business_id, idempotency_key) where idempotency_key is not null
    do nothing
  returning * into v_row;
  if v_row.id is null then
    select * into v_row from payments
      where business_id = p_business and idempotency_key = p_idempotency_key;
    if not found then
      raise exception 'record_payment: insert produced no row and no conflicting row exists '
                      '(business %, key %)', p_business, p_idempotency_key;
    end if;
  end if;
  return row_to_json(v_row);
end $$;
revoke execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) from public, anon;
grant execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) to authenticated;
create or replace function public.record_quick_sale(
  p_business        uuid,
  p_amount_cents    integer,
  p_method          text,
  p_client          uuid    default null,
  p_staff           uuid    default null,
  p_branch          uuid    default null,
  p_note            text    default null,
  p_idempotency_key text    default null,
  p_paid            boolean default true)
returns json language plpgsql security definer set search_path = public as $$
declare v_sale sales; v_payment json; v_existing sales;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'a quick sale must have a positive amount';
  end if;
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(p_business::text || ':' || p_idempotency_key, 0));
    select s.* into v_existing from sales s
      join payments p on p.sale_id = s.id
     where p.business_id = p_business and p.idempotency_key = p_idempotency_key;
    if found then
      return json_build_object('sale', row_to_json(v_existing), 'replayed', true);
    end if;
  end if;
  insert into sales (business_id, client_id, kind, amount_cents, branch_id, staff_id, note)
  values (p_business, p_client, 'quick_sale', p_amount_cents, p_branch, p_staff, p_note)
  returning * into v_sale;
  if p_paid then
    v_payment := public.record_payment(
      p_business        => p_business,
      p_method          => p_method,
      p_amount_cents    => p_amount_cents,
      p_sale            => v_sale.id,
      p_client          => p_client,
      p_staff           => p_staff,
      p_kind            => 'payment',
      p_branch          => coalesce(p_branch, v_sale.branch_id),
      p_idempotency_key => p_idempotency_key);
  end if;
  return json_build_object('sale', row_to_json(v_sale), 'payment', v_payment,
                           'replayed', false);
end $$;
revoke execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) from public, anon;
grant execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) to authenticated;
create table public.cash_drawer_sessions (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete cascade,
  branch_id           uuid not null,
  opened_at           timestamptz not null default now(),
  opened_by           uuid default auth.uid(),
  opening_float_cents integer not null default 0 check (opening_float_cents >= 0),
  closed_at           timestamptz,
  closed_by           uuid,
  expected_cents      integer,
  counted_cents       integer,
  note                text,
  check ((closed_at is null and counted_cents is null and expected_cents is null)
      or (closed_at is not null and counted_cents is not null and expected_cents is not null))
);
create unique index one_open_drawer_per_branch
  on public.cash_drawer_sessions (branch_id) where closed_at is null;
create index cash_drawer_sessions_branch on public.cash_drawer_sessions (branch_id, opened_at);
alter table public.cash_drawer_sessions
  add constraint cash_drawer_sessions_id_business_key unique (id, business_id),
  add constraint cash_drawer_sessions_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);
alter table public.cash_drawer_sessions enable row level security;
create policy cash_drawer_sessions_select on public.cash_drawer_sessions for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
revoke all on public.cash_drawer_sessions from anon;
revoke insert, update, delete, truncate on public.cash_drawer_sessions from authenticated;
grant select on public.cash_drawer_sessions to authenticated;
create trigger trg_cash_drawer_sessions_audit
  after insert or update or delete on public.cash_drawer_sessions
  for each row execute function app.audit();
create table public.cash_drawer_movements (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null,
  session_id  uuid,
  kind        text not null check (kind in
                ('open_float','sale_cash','pay_in','pay_out','close_variance')),
  amount_cents integer not null,
  payment_id  uuid,
  staff_id    uuid,
  note        text,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  check (kind <> 'pay_out' or amount_cents < 0),
  check (kind not in ('open_float','pay_in','sale_cash') or amount_cents <> 0)
);
create unique index one_drawer_movement_per_payment
  on public.cash_drawer_movements (payment_id) where payment_id is not null;
create index cash_drawer_movements_branch on public.cash_drawer_movements (branch_id, occurred_at);
create index cash_drawer_movements_session on public.cash_drawer_movements (session_id);
alter table public.cash_drawer_movements
  add constraint cash_drawer_movements_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id),
  add constraint cash_drawer_movements_session_same_tenant foreign key (session_id, business_id)
      references public.cash_drawer_sessions(id, business_id),
  add constraint cash_drawer_movements_payment_same_tenant foreign key (payment_id, business_id)
      references public.payments(id, business_id),
  add constraint cash_drawer_movements_staff_same_tenant foreign key (staff_id, business_id)
      references public.staff(id, business_id);
alter table public.cash_drawer_movements enable row level security;
create policy cash_drawer_movements_select on public.cash_drawer_movements for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
revoke all on public.cash_drawer_movements from anon;
revoke insert, update, delete, truncate on public.cash_drawer_movements from authenticated;
grant select on public.cash_drawer_movements to authenticated;
create trigger trg_cash_drawer_movements_append_only
  before update or delete on public.cash_drawer_movements
  for each row execute function app.forbid_mutation();
create trigger trg_cash_drawer_movements_audit
  after insert on public.cash_drawer_movements
  for each row execute function app.audit();
create or replace function app.open_drawer_session(p_branch uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.cash_drawer_sessions
   where branch_id = p_branch and closed_at is null
   limit 1
$$;
create or replace function app.on_payment_drawer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.method = 'cash' and new.branch_id is not null then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, payment_id, staff_id, occurred_at, note)
    values (new.business_id, new.branch_id, app.open_drawer_session(new.branch_id),
            'sale_cash', new.amount_cents, new.id, new.staff_id, new.occurred_at,
            'auto: ' || new.kind)
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger trg_payment_drawer
  after insert on public.payments
  for each row execute function app.on_payment_drawer();
create view public.cash_drawer_balance
with (security_invoker = on) as
select b.id                                        as branch_id,
       b.business_id,
       b.name                                      as branch_name,
       coalesce(sum(m.amount_cents), 0)::integer   as expected_cents,
       (select ds.id from public.cash_drawer_sessions ds
         where ds.branch_id = b.id and ds.closed_at is null
         limit 1)                                  as open_session_id,
       max(m.occurred_at)                          as last_movement_at
from public.branches b
left join public.cash_drawer_movements m on m.branch_id = b.id
where app.has_perm(b.business_id, 'view_finance')
group by b.id, b.business_id, b.name;
revoke all on public.cash_drawer_balance from anon;
grant select on public.cash_drawer_balance to authenticated;
create view public.cash_drawer_session_summary
with (security_invoker = on) as
select s.id            as session_id,
       s.business_id,
       s.branch_id,
       s.opened_at,
       s.closed_at,
       s.opening_float_cents,
       s.expected_cents,
       s.counted_cents,
       (s.counted_cents - s.expected_cents)          as variance_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'sale_cash'), 0)::integer as cash_sales_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'pay_in'),    0)::integer as pay_in_cents,
       coalesce(sum(m.amount_cents) filter (where m.kind = 'pay_out'),   0)::integer as pay_out_cents,
       coalesce(sum(m.amount_cents), 0)::integer                                     as session_net_cents
from public.cash_drawer_sessions s
left join public.cash_drawer_movements m on m.session_id = s.id
where app.has_perm(s.business_id, 'view_finance')
group by s.id;
revoke all on public.cash_drawer_session_summary from anon;
grant select on public.cash_drawer_session_summary to authenticated;
create or replace function public.open_drawer(
  p_business uuid, p_branch uuid, p_float_cents integer default 0)
returns json language plpgsql security definer set search_path = public as $$
declare v_row cash_drawer_sessions;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to operate the cash drawer (view_finance)';
  end if;
  if not exists (select 1 from branches where id = p_branch and business_id = p_business) then
    raise exception 'branch does not belong to this business';
  end if;
  if app.open_drawer_session(p_branch) is not null then
    raise exception 'this branch already has an open drawer session';
  end if;
  insert into cash_drawer_sessions (business_id, branch_id, opening_float_cents)
  values (p_business, p_branch, coalesce(p_float_cents, 0))
  returning * into v_row;
  if coalesce(p_float_cents, 0) > 0 then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, note)
    values (p_business, p_branch, v_row.id, 'open_float', p_float_cents, 'opening float');
  end if;
  return row_to_json(v_row);
end $$;
revoke execute on function public.open_drawer(uuid, uuid, integer) from public, anon;
grant execute on function public.open_drawer(uuid, uuid, integer) to authenticated;
create or replace function public.record_drawer_movement(
  p_business uuid, p_branch uuid, p_kind text, p_amount_cents integer,
  p_note text default null, p_staff uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row cash_drawer_movements; v_amt integer;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to move cash in or out of the drawer (view_finance)';
  end if;
  if not exists (select 1 from branches where id = p_branch and business_id = p_business) then
    raise exception 'branch does not belong to this business';
  end if;
  if p_kind not in ('pay_in','pay_out') then
    raise exception 'kind must be pay_in or pay_out (sale_cash is posted automatically; open_float and close_variance are posted by open_drawer/close_drawer)';
  end if;
  if coalesce(p_amount_cents, 0) = 0 then raise exception 'amount must be non-zero'; end if;
  v_amt := case when p_kind = 'pay_out' then -abs(p_amount_cents) else abs(p_amount_cents) end;
  insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                     amount_cents, staff_id, note)
  values (p_business, p_branch, app.open_drawer_session(p_branch), p_kind, v_amt, p_staff, p_note)
  returning * into v_row;
  return row_to_json(v_row);
end $$;
revoke execute on function public.record_drawer_movement(uuid, uuid, text, integer, text, uuid)
  from public, anon;
grant execute on function public.record_drawer_movement(uuid, uuid, text, integer, text, uuid)
  to authenticated;
create or replace function public.close_drawer(
  p_business uuid, p_session uuid, p_counted_cents integer, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_s cash_drawer_sessions; v_expected integer; v_variance integer;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to close the cash drawer (view_finance)';
  end if;
  select * into v_s from cash_drawer_sessions
    where id = p_session and business_id = p_business for update;
  if not found then raise exception 'drawer session not found'; end if;
  if v_s.closed_at is not null then raise exception 'drawer session already closed'; end if;
  if p_counted_cents is null or p_counted_cents < 0 then
    raise exception 'counted amount must be zero or positive';
  end if;
  select coalesce(sum(amount_cents), 0) into v_expected
    from cash_drawer_movements where branch_id = v_s.branch_id;
  v_variance := p_counted_cents - v_expected;
  update cash_drawer_sessions
     set closed_at = now(), closed_by = auth.uid(),
         expected_cents = v_expected, counted_cents = p_counted_cents,
         note = coalesce(p_note, note)
   where id = p_session;
  if v_variance <> 0 then
    insert into cash_drawer_movements (business_id, branch_id, session_id, kind,
                                       amount_cents, note)
    values (p_business, v_s.branch_id, p_session, 'close_variance', v_variance,
            'close: counted ' || p_counted_cents || ' vs expected ' || v_expected);
  end if;
  return json_build_object('session_id', p_session, 'expected_cents', v_expected,
                          'counted_cents', p_counted_cents, 'variance_cents', v_variance);
end $$;
revoke execute on function public.close_drawer(uuid, uuid, integer, text) from public, anon;
grant execute on function public.close_drawer(uuid, uuid, integer, text) to authenticated;
create table public.expense_recurrences (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  branch_id      uuid,
  name           text not null,
  category       text,
  supplier       text,
  amount_cents   integer not null check (amount_cents >= 0),
  currency       text not null default 'SGD',
  fx_rate_to_base numeric not null default 1 check (fx_rate_to_base > 0),
  cadence        text not null check (cadence in ('weekly','monthly','annual')),
  starts_on      date not null default current_date,
  ends_on        date,
  next_run_on    date not null,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index expense_recurrences_due on public.expense_recurrences (next_run_on) where active;
alter table public.expense_recurrences
  add constraint expense_recurrences_id_business_key unique (id, business_id),
  add constraint expense_recurrences_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id);
alter table public.expense_recurrences enable row level security;
create policy expense_recurrences_all on public.expense_recurrences for all to authenticated
  using (app.has_perm(business_id, 'view_finance'))
  with check (app.has_perm(business_id, 'view_finance'));
revoke all on public.expense_recurrences from anon;
revoke truncate on public.expense_recurrences from authenticated;
grant select, insert, update, delete on public.expense_recurrences to authenticated;
create trigger trg_expense_recurrences_audit
  after insert or update or delete on public.expense_recurrences
  for each row execute function app.audit();
create table public.expenses (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  branch_id       uuid,
  category        text,
  supplier        text,
  description     text,
  amount_cents    integer not null check (amount_cents >= 0),
  currency        text not null default 'SGD',
  fx_rate_to_base numeric not null default 1 check (fx_rate_to_base > 0),
  occurred_on     date not null default current_date,
  voided_at       timestamptz,
  voided_by       uuid,
  recurrence_id   uuid,
  period_on       date,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid()
);
create unique index one_expense_per_recurrence_period
  on public.expenses (recurrence_id, period_on)
  where recurrence_id is not null;
create index expenses_business_date on public.expenses (business_id, occurred_on);
create index expenses_branch_date   on public.expenses (branch_id, occurred_on);
create index expenses_live          on public.expenses (business_id, occurred_on) where voided_at is null;
alter table public.expenses
  add constraint expenses_branch_same_tenant foreign key (branch_id, business_id)
      references public.branches(id, business_id),
  add constraint expenses_recurrence_same_tenant foreign key (recurrence_id, business_id)
      references public.expense_recurrences(id, business_id);
alter table public.expenses enable row level security;
create policy expenses_all on public.expenses for all to authenticated
  using (app.has_perm(business_id, 'view_finance'))
  with check (app.has_perm(business_id, 'view_finance'));
revoke all on public.expenses from anon;
revoke truncate on public.expenses from authenticated;
grant select, insert, update, delete on public.expenses to authenticated;
create trigger trg_expenses_audit
  after insert or update or delete on public.expenses
  for each row execute function app.audit();
create or replace function public.set_expense_void(
  p_business uuid, p_expense uuid, p_void boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_row expenses;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to void an expense (view_finance)';
  end if;
  update expenses
     set voided_at = case when p_void then now() else null end,
         voided_by = case when p_void then auth.uid() else null end
   where id = p_expense and business_id = p_business
  returning * into v_row;
  if not found then raise exception 'expense not found'; end if;
  return row_to_json(v_row);
end $$;
revoke execute on function public.set_expense_void(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_expense_void(uuid, uuid, boolean) to authenticated;
create or replace function app.run_expense_recurrences()
returns void language plpgsql security definer set search_path = public as $$
declare r record; guard integer; v_next date;
begin
  for r in select * from expense_recurrences
      where active and next_run_on <= current_date loop
    guard := 0;
    v_next := r.next_run_on;
    while v_next <= current_date and guard < 60 loop
      exit when r.ends_on is not null and v_next > r.ends_on;
      insert into expenses (business_id, branch_id, category, supplier, description,
                            amount_cents, currency, fx_rate_to_base, occurred_on,
                            recurrence_id, period_on, note)
      values (r.business_id, r.branch_id, r.category, r.supplier, r.name,
              r.amount_cents, r.currency, r.fx_rate_to_base, v_next,
              r.id, v_next, 'auto: recurring expense')
      on conflict do nothing;
      v_next := case r.cadence
                  when 'weekly' then v_next + 7
                  when 'annual' then (v_next + interval '1 year')::date
                  else (v_next + interval '1 month')::date
                end;
      guard := guard + 1;
    end loop;
    update expense_recurrences
       set next_run_on = v_next,
           active = case when r.ends_on is not null and v_next > r.ends_on then false else active end
     where id = r.id;
  end loop;
end $$;
select cron.schedule('frenly-expense-recurrences', '20 19 * * *',
                     'select app.run_expense_recurrences()');
create or replace function public.get_revenue_summary(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_accrual bigint; v_cash bigint; v_expenses bigint;
        v_unpaid bigint; v_collected bigint;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)';
  end if;
  select coalesce(sum(s.amount_cents), 0) into v_accrual
    from sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at::date between p_from and p_to
     and (p_branch is null or s.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_cash
    from payments p
    join sales s
      on  s.id = p.sale_id
       or (p.sale_id is null
           and p.appointment_id is not null
           and s.appointment_id = p.appointment_id)
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_collected
    from payments p
   where p.business_id = p_business
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(b.balance_cents), 0) into v_unpaid
    from sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at::date between p_from and p_to
     and (p_branch is null or b.branch_id = p_branch);
  select coalesce(sum(round(e.amount_cents * e.fx_rate_to_base)), 0) into v_expenses
    from expenses e
   where e.business_id = p_business
     and e.voided_at is null
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
revoke execute on function public.get_revenue_summary(uuid, date, date, uuid) from public, anon;
grant execute on function public.get_revenue_summary(uuid, date, date, uuid) to authenticated;
create view public.sale_commission
with (security_invoker = on) as
select s.id            as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       coalesce(
         case
           when s.kind = 'service'
             then coalesce(svc.commission_bps, st.commission_service_bps)
           else st.commission_product_bps
         end, 0)       as rate_bps,
       case
         when st.id is null then 0
         when st.commission_starts_on is not null
              and s.occurred_at::date < st.commission_starts_on then 0
         else floor(s.amount_cents * coalesce(
                case
                  when s.kind = 'service'
                    then coalesce(svc.commission_bps, st.commission_service_bps)
                  else st.commission_product_bps
                end, 0) / 10000.0)
       end::integer    as commission_cents
from public.sales s
left join public.staff st       on st.id = s.staff_id
left join public.appointments a on a.id = s.appointment_id
left join public.services svc   on svc.id = a.service_id
where app.has_perm(s.business_id, 'view_finance');
revoke all on public.sale_commission from anon;
grant select on public.sale_commission to authenticated;