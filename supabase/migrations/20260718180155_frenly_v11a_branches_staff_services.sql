alter table public.sales        add constraint sales_id_business_uk    unique (id, business_id);
alter table public.appointments add constraint appts_id_business_uk    unique (id, business_id);
alter table public.services     add constraint services_id_business_uk unique (id, business_id);
alter table public.staff        add constraint staff_id_business_uk    unique (id, business_id);
alter table public.clients      add constraint clients_id_business_uk  unique (id, business_id);
alter table public.businesses
  add column tax_rate_bps integer not null default 0
    check (tax_rate_bps >= 0 and tax_rate_bps <= 10000);
create table public.branches (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  address      text,
  phone        text,
  email        text,
  tax_rate_bps integer check (tax_rate_bps >= 0 and tax_rate_bps <= 10000),
  timezone     text not null default 'Asia/Singapore',
  active       boolean not null default true,
  is_default   boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint branches_id_business_uk unique (id, business_id)
);
create unique index one_default_branch_per_business
  on public.branches (business_id) where is_default;
create index branches_business_active on public.branches (business_id, active);
alter table public.branches enable row level security;
create policy branches_select on public.branches for select to authenticated
  using (app.is_salon_member(business_id));
create policy branches_write on public.branches for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branches from anon;
grant select, insert, update, delete on public.branches to authenticated;
create trigger trg_branches_audit
  after insert or update or delete on public.branches
  for each row execute function app.audit();
create or replace function app.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger trg_branches_touch
  before update on public.branches
  for each row execute function app.touch_updated_at();
create table public.branch_hours (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null references public.branches(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  opens_at    time not null,
  closes_at   time not null,
  unique (branch_id, weekday),
  check (closes_at > opens_at)
);
create index branch_hours_branch on public.branch_hours (branch_id, weekday);
alter table public.branch_hours enable row level security;
create policy branch_hours_select on public.branch_hours for select to authenticated
  using (app.is_salon_member(business_id));
create policy branch_hours_write on public.branch_hours for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branch_hours from anon;
grant select, insert, update, delete on public.branch_hours to authenticated;
create table public.branch_breaks (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null references public.branches(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  starts_at   time not null,
  ends_at     time not null,
  check (ends_at > starts_at)
);
create index branch_breaks_branch on public.branch_breaks (branch_id, weekday);
alter table public.branch_breaks enable row level security;
create policy branch_breaks_select on public.branch_breaks for select to authenticated
  using (app.is_salon_member(business_id));
create policy branch_breaks_write on public.branch_breaks for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branch_breaks from anon;
grant select, insert, update, delete on public.branch_breaks to authenticated;
create or replace function app.default_branch(p_business uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.branches
   where business_id = p_business and is_default
   limit 1
$$;
create or replace function app.effective_tax_bps(p_branch uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(br.tax_rate_bps, b.tax_rate_bps)
  from public.branches br
  join public.businesses b on b.id = br.business_id
  where br.id = p_branch
$$;
insert into public.branches (business_id, name, is_default, active)
select b.id, b.name, true, true
from public.businesses b
where not exists (select 1 from public.branches x
                   where x.business_id = b.id and x.is_default);
alter table public.appointments add column branch_id uuid;
alter table public.appointments add constraint appointments_branch_fk
  foreign key (branch_id, business_id) references public.branches(id, business_id)
  on delete no action;
alter table public.sales add column branch_id uuid;
alter table public.sales add constraint sales_branch_fk
  foreign key (branch_id, business_id) references public.branches(id, business_id)
  on delete no action;
alter table public.sales add column staff_id uuid;
alter table public.sales add constraint sales_staff_fk
  foreign key (staff_id, business_id) references public.staff(id, business_id)
  on delete no action;
create index appointments_branch on public.appointments (branch_id, starts_at);
create index sales_branch on public.sales (branch_id, occurred_at);
create index sales_staff on public.sales (staff_id, occurred_at);
update public.appointments a
   set branch_id = app.default_branch(a.business_id)
 where a.branch_id is null;
select app.begin_sales_backfill('frenly_v11a_branches_staff_services',
         'populate the new sales.branch_id column on pre-branch historical rows');
update public.sales s
   set branch_id = app.default_branch(s.business_id)
 where s.branch_id is null;
select app.end_sales_backfill();
create or replace function app.set_row_branch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.branch_id is null then
    new.branch_id := app.default_branch(new.business_id);
  end if;
  return new;
end $$;
create trigger trg_sales_default_branch
  before insert on public.sales
  for each row execute function app.set_row_branch();
create trigger trg_appointments_default_branch
  before insert on public.appointments
  for each row execute function app.set_row_branch();
create or replace function public.create_business(p_name text, p_slug text, p_industry text, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid; rec businesses; v_staff uuid; v_branch uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'sign in required'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'business name required'; end if;
  insert into businesses (name, slug, industry, enabled_modules)
  values (trim(p_name), p_slug, coalesce(p_industry,'other'),
          coalesce(p_modules, array['dashboard','clients','sales','loyalty','retention','referrals']))
  returning * into rec;
  insert into staff (business_id, user_id, role, full_name)
  values (rec.id, v_uid, 'owner', coalesce(auth.jwt()->>'email','Owner'))
  returning id into v_staff;
  insert into branches (business_id, name, is_default, active)
  values (rec.id, trim(p_name), true, true)
  returning id into v_branch;
  insert into staff_branches (business_id, staff_id, branch_id)
  values (rec.id, v_staff, v_branch);
  insert into loyalty_programs (business_id, kind, earn_points_per_dollar,
                                redeem_points, reward_credit_cents, active)
  values (rec.id, 'points', 1, 800, 2000, true);
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (rec.id, v_uid, 'ONBOARD', 'businesses', rec.id,
          json_build_object('name', rec.name, 'industry', rec.industry)::jsonb);
  return row_to_json(rec);
end $$;
revoke execute on function public.create_business(text, text, text, text[]) from public, anon;
grant execute on function public.create_business(text, text, text, text[]) to authenticated;
alter table public.staff
  alter column user_id drop not null;
alter table public.staff
  add column email                  text,
  add column phone                  text,
  add column title                  text,
  add column calendar_color         text not null default '#7C9CBF'
    check (calendar_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column active                 boolean not null default true,
  add column commission_service_bps integer check (commission_service_bps between 0 and 10000),
  add column commission_product_bps integer check (commission_product_bps between 0 and 10000),
  add column commission_starts_on   date;
create index staff_business_active on public.staff (business_id, active);
create trigger trg_staff_audit
  after insert or update or delete on public.staff
  for each row execute function app.audit();
create table public.staff_branches (
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null,
  branch_id   uuid not null,
  primary key (staff_id, branch_id),
  foreign key (staff_id,  business_id) references public.staff(id, business_id)    on delete cascade,
  foreign key (branch_id, business_id) references public.branches(id, business_id) on delete cascade
);
create index staff_branches_business on public.staff_branches (business_id);
alter table public.staff_branches enable row level security;
create policy staff_branches_all on public.staff_branches for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_branches from anon;
grant select, insert, update, delete on public.staff_branches to authenticated;
create table public.staff_services (
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null,
  service_id  uuid not null,
  primary key (staff_id, service_id),
  foreign key (staff_id,   business_id) references public.staff(id, business_id)    on delete cascade,
  foreign key (service_id, business_id) references public.services(id, business_id) on delete cascade
);
create index staff_services_business on public.staff_services (business_id);
alter table public.staff_services enable row level security;
create policy staff_services_all on public.staff_services for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_services from anon;
grant select, insert, update, delete on public.staff_services to authenticated;
create table public.staff_hours (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null references public.staff(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  starts_at   time not null,
  ends_at     time not null,
  unique (staff_id, weekday),
  check (ends_at > starts_at)
);
create index staff_hours_staff on public.staff_hours (staff_id, weekday);
alter table public.staff_hours enable row level security;
create policy staff_hours_select on public.staff_hours for select to authenticated
  using (app.is_salon_member(business_id));
create policy staff_hours_write on public.staff_hours for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_hours from anon;
grant select, insert, update, delete on public.staff_hours to authenticated;
create table public.staff_off_days (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null references public.staff(id) on delete cascade,
  starts_on   date not null,
  ends_on     date not null,
  reason      text,
  created_at  timestamptz not null default now(),
  check (ends_on >= starts_on)
);
create index staff_off_days_staff on public.staff_off_days (staff_id, starts_on, ends_on);
alter table public.staff_off_days enable row level security;
create policy staff_off_days_select on public.staff_off_days for select to authenticated
  using (app.is_salon_member(business_id));
create policy staff_off_days_write on public.staff_off_days for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_off_days from anon;
grant select, insert, update, delete on public.staff_off_days to authenticated;
create trigger trg_staff_off_days_audit
  after insert or update or delete on public.staff_off_days
  for each row execute function app.audit();
insert into public.staff_branches (business_id, staff_id, branch_id)
select s.business_id, s.id, app.default_branch(s.business_id)
from public.staff s
where app.default_branch(s.business_id) is not null
on conflict do nothing;
alter table public.services
  add column description           text,
  add column category              text,
  add column deposit_cents         integer not null default 0 check (deposit_cents >= 0),
  add column processing_time_min   integer not null default 0 check (processing_time_min >= 0),
  add column buffer_before_min     integer not null default 0 check (buffer_before_min >= 0),
  add column buffer_after_min      integer not null default 0 check (buffer_after_min >= 0),
  add column commission_bps        integer check (commission_bps between 0 and 10000),
  add column show_on_booking_page  boolean not null default true,
  add column apply_tax             boolean not null default true;
create index services_business_active on public.services (business_id, active);
create table public.service_branches (
  business_id uuid not null references public.businesses(id) on delete cascade,
  service_id  uuid not null,
  branch_id   uuid not null,
  primary key (service_id, branch_id),
  foreign key (service_id, business_id) references public.services(id, business_id) on delete cascade,
  foreign key (branch_id,  business_id) references public.branches(id, business_id) on delete cascade
);
create index service_branches_business on public.service_branches (business_id);
alter table public.service_branches enable row level security;
create policy service_branches_all on public.service_branches for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.service_branches from anon;
grant select, insert, update, delete on public.service_branches to authenticated;
insert into public.service_branches (business_id, service_id, branch_id)
select s.business_id, s.id, app.default_branch(s.business_id)
from public.services s
where app.default_branch(s.business_id) is not null
on conflict do nothing;
create view public.service_bookable
with (security_invoker = on) as
select s.id                                as service_id,
       s.business_id,
       s.active,
       s.show_on_booking_page,
       count(distinct st.id)               as staff_count,
       count(distinct sb.branch_id)        as branch_count,
       (s.active
        and count(distinct st.id) > 0)     as bookable
from public.services s
left join public.staff_services  ss on ss.service_id = s.id
left join public.staff           st on st.id = ss.staff_id and st.active
left join public.service_branches sb on sb.service_id = s.id
group by s.id, s.business_id, s.active, s.show_on_booking_page;
revoke all on public.service_bookable from anon;
grant select on public.service_bookable to authenticated;