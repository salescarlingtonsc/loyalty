-- FRENLY v6 — operations modules + THE relationship: appointment completion -> sale -> loyalty.

-- 1) Appointments upgrades
create table public.resources (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  active       boolean not null default true
);
alter table public.resources enable row level security;
create policy resources_all on public.resources for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));

alter table public.appointments
  add column service_id uuid references public.services(id) on delete set null,
  add column resource_id uuid references public.resources(id) on delete set null,
  add column note text;

-- 2) Sales gain appointment + product linkage
alter table public.sales
  add column appointment_id uuid references public.appointments(id) on delete set null,
  add column product_id uuid references public.products(id) on delete set null,
  add column qty integer check (qty is null or qty > 0);
create unique index one_sale_per_appointment on public.sales (appointment_id)
  where appointment_id is not null;

-- 3) THE relationship: completing an appointment books a sale -> loyalty engine fires
create or replace function app.on_appointment_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_amount integer;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    v_amount := coalesce(nullif(new.total_cents,0),
                 (select price_cents from services where id = new.service_id), 0);
    insert into sales (business_id, client_id, kind, amount_cents, appointment_id, note)
    values (new.business_id, new.client_id, 'service', v_amount, new.id,
            'appointment completed')
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger trg_appointment_completed after update on public.appointments
  for each row execute function app.on_appointment_completed();

-- 4) Inventory: stock view + FEFO auto-deduct on retail sales with a product
create view public.product_stock with (security_invoker = true) as
  select p.id as product_id, p.business_id, coalesce(sum(b.qty),0)::integer as stock
  from public.products p left join public.stock_batches b on b.product_id = p.id
  group by p.id, p.business_id;

create or replace function app.on_sale_stock_deduct()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_need integer; bt record; v_take integer;
begin
  if new.product_id is not null then
    v_need := coalesce(new.qty, 1);
    for bt in select id, qty from stock_batches
      where product_id = new.product_id and qty > 0
      order by expires_on nulls last, received_on loop
      exit when v_need <= 0;
      v_take := least(bt.qty, v_need);
      update stock_batches set qty = qty - v_take where id = bt.id;
      v_need := v_need - v_take;
    end loop;
  end if;
  return new;
end $$;
create trigger trg_sale_stock_deduct after insert on public.sales
  for each row execute function app.on_sale_stock_deduct();

-- 5) Waitlist
create table public.waitlist (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid references public.clients(id) on delete set null,
  name         text not null,
  phone        text,
  service_id   uuid references public.services(id) on delete set null,
  preferred    text,
  notes        text,
  status       text not null default 'waiting'
               check (status in ('waiting','contacted','booked','removed')),
  created_at   timestamptz not null default now()
);
create index on public.waitlist (business_id, status);
alter table public.waitlist enable row level security;
create policy waitlist_all on public.waitlist for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));

-- 6) Packages (prepaid sessions)
create table public.package_plans (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  price_cents  integer not null check (price_cents >= 0),
  sessions     integer not null check (sessions > 0),
  service_id   uuid references public.services(id) on delete set null,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create table public.client_packages (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  plan_id      uuid not null references public.package_plans(id) on delete restrict,
  remaining    integer not null check (remaining >= 0),
  status       text not null default 'active' check (status in ('active','used_up')),
  purchased_at timestamptz not null default now()
);
create index on public.client_packages (business_id, client_id);
alter table public.package_plans enable row level security;
alter table public.client_packages enable row level security;
create policy pkgplans_all on public.package_plans for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy cpkg_select on public.client_packages for select to authenticated
  using (app.is_salon_member(business_id));

create or replace function public.sell_package(p_business uuid, p_client uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public as $$
declare plan record; cp client_packages;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into plan from package_plans where id = p_plan and business_id = p_business and active;
  if not found then raise exception 'package plan not found or inactive'; end if;
  insert into client_packages (business_id, client_id, plan_id, remaining)
  values (p_business, p_client, plan.sessions) , (p_business, p_client, p_plan, plan.sessions)
  returning * into cp;
  return row_to_json(cp);
end $$;

-- (fix: single correct insert)
create or replace function public.sell_package(p_business uuid, p_client uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public as $$
declare plan record; cp client_packages;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into plan from package_plans where id = p_plan and business_id = p_business and active;
  if not found then raise exception 'package plan not found or inactive'; end if;
  insert into client_packages (business_id, client_id, plan_id, remaining)
  values (p_business, p_client, p_plan, plan.sessions)
  returning * into cp;
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_client, 'retail', plan.price_cents, 'package sold: ' || plan.name);
  return row_to_json(cp);
end $$;
revoke execute on function public.sell_package(uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package(uuid, uuid, uuid) to authenticated;

create or replace function public.use_package_session(p_business uuid, p_cp uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare cp record; plan record;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into cp from client_packages where id = p_cp and business_id = p_business for update;
  if not found then raise exception 'package not found'; end if;
  if cp.remaining <= 0 then raise exception 'no sessions remaining'; end if;
  select * into plan from package_plans where id = cp.plan_id;
  update client_packages set remaining = remaining - 1,
    status = case when remaining - 1 = 0 then 'used_up' else 'active' end
    where id = cp.id;
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, cp.client_id, 'service', 0, 'package session used: ' || plan.name);
  return cp.remaining - 1;
end $$;
revoke execute on function public.use_package_session(uuid, uuid) from public, anon;
grant execute on function public.use_package_session(uuid, uuid) to authenticated;

-- 7) Bundles (catalog)
create table public.bundles (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  price_cents  integer not null check (price_cents >= 0),
  active       boolean not null default true
);
create table public.bundle_items (
  bundle_id   uuid not null references public.bundles(id) on delete cascade,
  service_id  uuid not null references public.services(id) on delete cascade,
  primary key (bundle_id, service_id)
);
alter table public.bundles enable row level security;
alter table public.bundle_items enable row level security;
create policy bundles_all on public.bundles for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy bundle_items_all on public.bundle_items for all to authenticated
  using (exists (select 1 from bundles b where b.id = bundle_id and app.is_salon_member(b.business_id)))
  with check (exists (select 1 from bundles b where b.id = bundle_id and app.is_salon_member(b.business_id)));

-- 8) Convert a portal booking request into a real appointment
create or replace function public.convert_booking_request(p_request uuid)
returns json language plpgsql security definer set search_path = public as $$
declare req record; v_client uuid; v_start timestamptz; v_end timestamptz; ap appointments;
begin
  select * into req from booking_requests where id = p_request;
  if not found then raise exception 'request not found'; end if;
  if not app.is_salon_member(req.business_id) then raise exception 'not a member of this business'; end if;
  select id into v_client from clients
    where business_id = req.business_id
      and ((req.phone is not null and phone = req.phone)
        or (req.email is not null and email = req.email)) limit 1;
  if v_client is null then
    insert into clients (business_id, full_name, phone, email)
    values (req.business_id, req.name, req.phone, req.email) returning id into v_client;
  end if;
  v_start := coalesce(req.preferred_at, now() + interval '1 day');
  v_end := v_start + coalesce((select make_interval(mins => duration_min)
            from services where id = req.service_id), interval '60 minutes');
  insert into appointments (business_id, client_id, service_id, starts_at, ends_at,
                            status, party_size, source, note)
  values (req.business_id, v_client, req.service_id, v_start, v_end,
          'booked', req.party_size, 'portal', req.notes)
  returning * into ap;
  update booking_requests set status = 'confirmed' where id = p_request;
  return row_to_json(ap);
end $$;
revoke execute on function public.convert_booking_request(uuid) from public, anon;
grant execute on function public.convert_booking_request(uuid) to authenticated;