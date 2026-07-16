-- FRENLY v2 — industry-agnostic SaaS (applied to Supabase kyzovonwnscrzmkvocid as
-- migration `frenly_v2_saas`). Tenancy rename, sales, points engine, retention
-- programs, booking requests, portal RPCs, automation triggers.

alter table public.salons rename to businesses;
alter table public.staff        rename column salon_id to business_id;
alter table public.clients      rename column salon_id to business_id;
alter table public.services     rename column salon_id to business_id;
alter table public.appointments rename column salon_id to business_id;
alter table public.products     rename column salon_id to business_id;
alter table public.loyalty_programs rename column salon_id to business_id;
alter table public.credit_ledger    rename column salon_id to business_id;
alter table public.referrals        rename column salon_id to business_id;
alter table public.gift_cards       rename column salon_id to business_id;

alter table public.businesses
  add column industry text not null default 'other',
  add column enabled_modules text[] not null default array['dashboard','clients','sales','loyalty','retention'];

create or replace function app.is_salon_member(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s
    where s.business_id = p_salon and s.user_id = auth.uid());
$$;
create or replace function app.is_salon_owner(p_salon uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s
    where s.business_id = p_salon and s.user_id = auth.uid() and s.role = 'owner');
$$;

drop view public.client_credit_balance;
create view public.client_credit_balance with (security_invoker = true) as
  select business_id, client_id, coalesce(sum(amount_cents),0) as balance_cents
  from public.credit_ledger group by business_id, client_id;

alter table public.clients
  add column gender text check (gender in ('female','male','other')),
  add column birth_date date,
  add column marketing_consent boolean not null default false,
  add column tags text[] not null default '{}';

alter table public.appointments
  add column party_size integer,
  add column source text not null default 'admin';

create table public.sales (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  client_id     uuid references public.clients(id) on delete set null,
  kind          text not null check (kind in ('service','retail','membership','quick_sale')),
  amount_cents  integer not null check (amount_cents >= 0),
  occurred_at   timestamptz not null default now(),
  note          text,
  created_at    timestamptz not null default now()
);
create index on public.sales (business_id, occurred_at);
create index on public.sales (business_id, client_id, occurred_at);

create table public.points_ledger (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  entry_type   text not null check (entry_type in ('earn','redeem','expire','adjust')),
  points       integer not null,
  sale_id      uuid references public.sales(id) on delete set null,
  reference    text,
  created_at   timestamptz not null default now()
);
create index on public.points_ledger (business_id, client_id, created_at);
create unique index points_earn_once_per_sale on public.points_ledger (sale_id)
  where entry_type = 'earn' and sale_id is not null;

create view public.client_points_balance with (security_invoker = true) as
  select business_id, client_id, coalesce(sum(points),0) as points
  from public.points_ledger group by business_id, client_id;

alter table public.loyalty_programs
  add column earn_points_per_dollar numeric not null default 1,
  add column redeem_points integer not null default 800;

create table public.retention_programs (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  goal_visits  integer not null check (goal_visits > 0),
  period_days  integer not null check (period_days > 0),
  reward_type  text not null check (reward_type in ('discount_pct','free_item','credit')),
  reward_value numeric not null default 0,
  reward_item  text,
  starts_on    date not null default current_date,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create index on public.retention_programs (business_id);

create table public.reward_grants (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  program_id    uuid not null references public.retention_programs(id) on delete cascade,
  client_id     uuid not null references public.clients(id) on delete cascade,
  period_index  integer not null,
  reward_type   text not null,
  reward_value  numeric not null default 0,
  reward_item   text,
  status        text not null default 'granted' check (status in ('granted','redeemed','expired')),
  granted_at    timestamptz not null default now(),
  unique (program_id, client_id, period_index)
);
create index on public.reward_grants (business_id, client_id);

create table public.booking_requests (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  email        text,
  phone        text,
  service_id   uuid references public.services(id) on delete set null,
  party_size   integer,
  preferred_at timestamptz,
  notes        text,
  status       text not null default 'new' check (status in ('new','confirmed','declined')),
  created_at   timestamptz not null default now()
);
create index on public.booking_requests (business_id, status);

alter table public.sales              enable row level security;
alter table public.points_ledger      enable row level security;
alter table public.retention_programs enable row level security;
alter table public.reward_grants      enable row level security;
alter table public.booking_requests   enable row level security;

create policy sales_all on public.sales for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy points_select on public.points_ledger for select to authenticated
  using (app.is_salon_member(business_id));
create policy points_insert on public.points_ledger for insert to authenticated
  with check (app.is_salon_member(business_id));
create policy retention_all on public.retention_programs for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy grants_select on public.reward_grants for select to authenticated
  using (app.is_salon_member(business_id));
create policy grants_update on public.reward_grants for update to authenticated
  using (app.is_salon_member(business_id));
create policy br_all on public.booking_requests for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));

create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; v_pts integer; v_idx integer; v_count integer;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is not null then
    select * into lp from loyalty_programs
      where business_id = new.business_id and active limit 1;
    if found and lp.kind = 'points' then
      v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      if v_pts > 0 then
        insert into points_ledger (business_id, client_id, entry_type, points, sale_id, reference)
        values (new.business_id, new.client_id, 'earn', v_pts, new.id, 'auto-earn on sale')
        on conflict do nothing;
      end if;
    end if;
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
            and s.occurred_at >= w_start and s.occurred_at < w_end;
        if v_count >= rp.goal_visits then
          begin
            insert into reward_grants (business_id, program_id, client_id, period_index,
                                       reward_type, reward_value, reward_item)
            values (new.business_id, rp.id, new.client_id, v_idx,
                    rp.reward_type, rp.reward_value, rp.reward_item);
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
              values (new.business_id, new.client_id, 'loyalty_earn',
                      rp.reward_value::integer, 'retention reward: ' || rp.name);
            end if;
          exception when unique_violation then null;
          end;
        end if;
      end if;
    end loop;
  end if;
  return new;
end $$;

create trigger trg_sale_recorded after insert on public.sales
  for each row execute function app.on_sale_recorded();

create or replace function public.redeem_points(p_business uuid, p_client uuid)
returns json language plpgsql security definer set search_path = public as $$
declare lp record; bal integer;
begin
  if not app.is_salon_member(p_business) then
    raise exception 'not a member of this business';
  end if;
  select * into lp from loyalty_programs where business_id = p_business and active limit 1;
  if not found then raise exception 'no active loyalty program'; end if;
  select coalesce(sum(points),0) into bal from points_ledger
    where business_id = p_business and client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;
  insert into points_ledger (business_id, client_id, entry_type, points, reference)
  values (p_business, p_client, 'redeem', -lp.redeem_points, 'redeemed to credit');
  insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
  values (p_business, p_client, 'loyalty_earn', lp.reward_credit_cents, 'points redemption');
  return json_build_object('points_spent', lp.redeem_points,
                           'credit_cents', lp.reward_credit_cents);
end $$;
revoke execute on function public.redeem_points(uuid, uuid) from public, anon;
grant execute on function public.redeem_points(uuid, uuid) to authenticated;

create or replace function public.get_business_public(p_slug text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', b.id, 'name', b.name, 'industry', b.industry, 'currency', b.currency,
    'services', coalesce((select json_agg(json_build_object(
        'id', s.id, 'name', s.name, 'price_cents', s.price_cents,
        'duration_min', s.duration_min))
      from services s where s.business_id = b.id and s.active), '[]'::json))
  from businesses b where b.slug = p_slug;
$$;

create or replace function public.request_booking(
  p_slug text, p_name text, p_email text, p_phone text,
  p_service uuid, p_party integer, p_preferred timestamptz, p_notes text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_id uuid;
begin
  select id into v_biz from businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'name required'; end if;
  insert into booking_requests (business_id, name, email, phone, service_id,
                                party_size, preferred_at, notes)
  values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.get_business_public(text) to anon, authenticated;
grant execute on function public.request_booking(text, text, text, text, uuid, integer, timestamptz, text) to anon, authenticated;
