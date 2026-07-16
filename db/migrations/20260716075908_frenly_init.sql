-- ============================================================
-- FRENLY — initial schema  (migration 0001_frenly_init)
-- Salon OS: tenancy, staff, clients, booking, inventory (FEFO),
-- loyalty-as-real-credit ledger, referrals, gift cards, leads.
-- RLS enabled on every table. Multi-tenant scoped by salon.
-- ============================================================

-- ---------- helper: current user's salon membership ----------
create schema if not exists app;

create or replace function app.is_salon_member(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.salon_id = p_salon and s.user_id = auth.uid()
  );
$$;

create or replace function app.is_salon_owner(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.salon_id = p_salon and s.user_id = auth.uid() and s.role = 'owner'
  );
$$;

-- ---------- tenancy ----------
create table public.salons (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  currency    text not null default 'SGD',
  created_at  timestamptz not null default now()
);

create table public.staff (
  id          uuid primary key default gen_random_uuid(),
  salon_id    uuid not null references public.salons(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null check (role in ('owner','manager','stylist','frontdesk')),
  full_name   text,
  created_at  timestamptz not null default now(),
  unique (salon_id, user_id)
);

-- ---------- clients (PII — strictest scope) ----------
create table public.clients (
  id          uuid primary key default gen_random_uuid(),
  salon_id    uuid not null references public.salons(id) on delete cascade,
  full_name   text not null,
  email       text,
  phone       text,
  notes       text,
  created_at  timestamptz not null default now()
);
create index on public.clients (salon_id);

-- ---------- services & booking ----------
create table public.services (
  id            uuid primary key default gen_random_uuid(),
  salon_id      uuid not null references public.salons(id) on delete cascade,
  name          text not null,
  price_cents   integer not null check (price_cents >= 0),
  duration_min  integer not null check (duration_min > 0),
  active        boolean not null default true
);
create index on public.services (salon_id);

create table public.appointments (
  id           uuid primary key default gen_random_uuid(),
  salon_id     uuid not null references public.salons(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  staff_id     uuid references public.staff(id) on delete set null,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  status       text not null default 'booked'
               check (status in ('booked','completed','cancelled','no_show')),
  total_cents  integer not null default 0,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index on public.appointments (salon_id, starts_at);

create table public.appointment_services (
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  service_id     uuid not null references public.services(id) on delete restrict,
  price_cents    integer not null check (price_cents >= 0),
  primary key (appointment_id, service_id)
);

-- ---------- inventory with FEFO batches ----------
create table public.products (
  id                 uuid primary key default gen_random_uuid(),
  salon_id           uuid not null references public.salons(id) on delete cascade,
  name               text not null,
  sku                text,
  retail_price_cents integer not null default 0 check (retail_price_cents >= 0),
  active             boolean not null default true,
  unique (salon_id, sku)
);

create table public.stock_batches (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products(id) on delete cascade,
  qty         integer not null check (qty >= 0),
  expires_on  date,
  received_on date not null default current_date
);
create index on public.stock_batches (product_id, expires_on); -- FEFO drain order

-- ---------- loyalty: real spendable credit, one ledger ----------
create table public.loyalty_programs (
  id                  uuid primary key default gen_random_uuid(),
  salon_id            uuid not null unique references public.salons(id) on delete cascade,
  kind                text not null check (kind in ('points','stamps')),
  earn_rate_bps       integer not null default 500,  -- points minted per dollar, basis points
  stamp_target        integer,                        -- stamps needed for reward (stamps mode)
  reward_credit_cents integer not null default 0,
  active              boolean not null default true
);

create table public.credit_ledger (
  id          uuid primary key default gen_random_uuid(),
  salon_id    uuid not null references public.salons(id) on delete cascade,
  client_id   uuid not null references public.clients(id) on delete cascade,
  entry_type  text not null check (entry_type in
              ('loyalty_earn','loyalty_redeem','referral_reward',
               'gift_card_load','membership_credit','manual_adjust','spend')),
  amount_cents integer not null,           -- signed: earn +, spend/redeem -
  reference   text,
  created_at  timestamptz not null default now()
);
create index on public.credit_ledger (salon_id, client_id, created_at);

create or replace view public.client_credit_balance
with (security_invoker = true) as
  select salon_id, client_id, coalesce(sum(amount_cents),0) as balance_cents
  from public.credit_ledger group by salon_id, client_id;

-- ---------- referrals (self-funding: reward after qualified visit) ----------
create table public.referrals (
  id                  uuid primary key default gen_random_uuid(),
  salon_id            uuid not null references public.salons(id) on delete cascade,
  referrer_client_id  uuid not null references public.clients(id) on delete cascade,
  referred_client_id  uuid references public.clients(id) on delete set null,
  status              text not null default 'pending'
                      check (status in ('pending','qualified','rewarded')),
  reward_cents        integer not null default 0,
  qualified_at        timestamptz,
  created_at          timestamptz not null default now()
);
create index on public.referrals (salon_id);

-- ---------- gift cards ----------
create table public.gift_cards (
  id                   uuid primary key default gen_random_uuid(),
  salon_id             uuid not null references public.salons(id) on delete cascade,
  code                 text not null unique,
  initial_cents        integer not null check (initial_cents > 0),
  balance_cents        integer not null check (balance_cents >= 0),
  purchaser_client_id  uuid references public.clients(id) on delete set null,
  recipient_email      text,
  status               text not null default 'active'
                       check (status in ('active','redeemed','void')),
  created_at           timestamptz not null default now()
);
create index on public.gift_cards (salon_id);

-- ---------- website leads (dev-site email capture; PII) ----------
create table public.leads (
  id          uuid primary key default gen_random_uuid(),
  source      text not null default 'frenly-site',
  email       text not null,
  name        text,
  message     text,
  created_at  timestamptz not null default now()
);

-- ============================================================
-- RLS — enabled on ALL tables
-- ============================================================
alter table public.salons               enable row level security;
alter table public.staff                enable row level security;
alter table public.clients              enable row level security;
alter table public.services             enable row level security;
alter table public.appointments         enable row level security;
alter table public.appointment_services enable row level security;
alter table public.products             enable row level security;
alter table public.stock_batches        enable row level security;
alter table public.loyalty_programs     enable row level security;
alter table public.credit_ledger        enable row level security;
alter table public.referrals            enable row level security;
alter table public.gift_cards           enable row level security;
alter table public.leads                enable row level security;

-- salons: members read; owners update; any authed user can create their salon
create policy salons_select on public.salons for select to authenticated
  using (app.is_salon_member(id));
create policy salons_insert on public.salons for insert to authenticated
  with check (true);
create policy salons_update on public.salons for update to authenticated
  using (app.is_salon_owner(id));

-- staff: members read own salon roster; owners manage
create policy staff_select on public.staff for select to authenticated
  using (app.is_salon_member(salon_id));
create policy staff_insert on public.staff for insert to authenticated
  with check (app.is_salon_owner(salon_id) or not exists
    (select 1 from public.staff s where s.salon_id = staff.salon_id)); -- bootstrap first owner
create policy staff_update on public.staff for update to authenticated
  using (app.is_salon_owner(salon_id));
create policy staff_delete on public.staff for delete to authenticated
  using (app.is_salon_owner(salon_id));

-- generic member-scoped CRUD for tenant tables
create policy clients_all on public.clients for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy services_all on public.services for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy appointments_all on public.appointments for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy appt_services_all on public.appointment_services for all to authenticated
  using (exists (select 1 from public.appointments a
         where a.id = appointment_id and app.is_salon_member(a.salon_id)))
  with check (exists (select 1 from public.appointments a
         where a.id = appointment_id and app.is_salon_member(a.salon_id)));
create policy products_all on public.products for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy stock_batches_all on public.stock_batches for all to authenticated
  using (exists (select 1 from public.products p
         where p.id = product_id and app.is_salon_member(p.salon_id)))
  with check (exists (select 1 from public.products p
         where p.id = product_id and app.is_salon_member(p.salon_id)));
create policy loyalty_programs_all on public.loyalty_programs for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy credit_ledger_select on public.credit_ledger for select to authenticated
  using (app.is_salon_member(salon_id));
create policy credit_ledger_insert on public.credit_ledger for insert to authenticated
  with check (app.is_salon_member(salon_id));  -- append-only: no update/delete policies
create policy referrals_all on public.referrals for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));
create policy gift_cards_all on public.gift_cards for all to authenticated
  using (app.is_salon_member(salon_id)) with check (app.is_salon_member(salon_id));

-- leads: anon may INSERT only (website form). No select/update/delete for
-- anon or authenticated — reads happen via service role in your backend.
create policy leads_insert_anon on public.leads for insert to anon, authenticated
  with check (true);
