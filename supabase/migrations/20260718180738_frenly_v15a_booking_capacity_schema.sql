-- ============================================================================
-- Frenly v15a — Booking capacity (tables), holds, notifications, intl phone.
-- SCHEMA layer only (tables, columns, constraints, indexes, RLS, helpers, view,
-- realtime). Flows/triggers/cron come in v15b.
-- ============================================================================

-- ---------- WS2/WS3/WS5: firm-level booking settings on businesses ----------
alter table public.businesses
  add column if not exists booking_overflow      text    not null default 'waitlist',
  add column if not exists booking_hold_minutes  integer not null default 15,
  add column if not exists notify_new_bookings   boolean not null default true,
  add column if not exists booking_auto_confirm  boolean not null default true;

alter table public.businesses
  add constraint businesses_booking_overflow_check
  check (booking_overflow in ('waitlist','reject'));
alter table public.businesses
  add constraint businesses_booking_hold_minutes_check
  check (booking_hold_minutes >= 0);

-- ---------- WS1: table-type capacity pool ----------
create table if not exists public.booking_tables (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name        text not null,
  pax         integer,                              -- informational seat count (nullable)
  quantity    integer not null check (quantity >= 0),
  sort        integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists booking_tables_business_idx on public.booking_tables(business_id);

alter table public.booking_tables enable row level security;

create policy booking_tables_read on public.booking_tables
  for select to authenticated using (app.is_salon_member(business_id));
create policy booking_tables_write on public.booking_tables
  for all to authenticated
  using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
create policy booking_tables_sa_read on public.booking_tables
  for select to authenticated using (app.is_super_admin());

revoke all on public.booking_tables from anon;
grant select, insert, update, delete on public.booking_tables to authenticated;
grant all on public.booking_tables to service_role;

-- ---------- WS5: notifications ----------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind        text not null check (kind in
                ('booking_new','booking_waitlisted','change_request','booking_expired','waitlist_ready')),
  title       text not null,
  body        text,
  ref_table   text,
  ref_id      uuid,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index if not exists notifications_business_created_idx
  on public.notifications(business_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications(business_id) where read_at is null;

alter table public.notifications enable row level security;

create policy notifications_select on public.notifications
  for select to authenticated using (app.is_salon_member(business_id));
create policy notifications_update on public.notifications
  for update to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy notifications_sa_read on public.notifications
  for select to authenticated using (app.is_super_admin());
-- NB: no INSERT policy -> only SECURITY DEFINER triggers/RPCs (run as owner) can insert.

revoke all on public.notifications from anon;
grant select, update on public.notifications to authenticated;
grant all on public.notifications to service_role;

-- ---------- WS1/WS2/WS3: booking_requests gains table hold + link + expiry ----------
alter table public.booking_requests
  add column if not exists table_type_id  uuid references public.booking_tables(id) on delete set null,
  add column if not exists appointment_id uuid references public.appointments(id)   on delete set null,
  add column if not exists expires_at     timestamptz;

alter table public.booking_requests drop constraint if exists booking_requests_status_check;
alter table public.booking_requests
  add constraint booking_requests_status_check
  check (status in ('new','pending','confirmed','waitlisted','declined','expired','cancelled'));

create index if not exists booking_requests_expiry_idx
  on public.booking_requests(status, expires_at) where expires_at is not null;
create index if not exists booking_requests_table_type_idx
  on public.booking_requests(table_type_id) where table_type_id is not null;

-- ---------- WS1: appointments can hold a table type ----------
alter table public.appointments
  add column if not exists table_type_id uuid references public.booking_tables(id) on delete set null;
create index if not exists appointments_table_type_idx
  on public.appointments(table_type_id) where table_type_id is not null;

-- ---------- WS2: waitlist links back to the originating request + remembers table ----------
alter table public.waitlist
  add column if not exists booking_request_id uuid references public.booking_requests(id) on delete set null,
  add column if not exists table_type_id      uuid references public.booking_tables(id)   on delete set null;

-- ---------- WS4: phone match key (SG folds to 8-digit; else bare digits) ----------
create or replace function app.phone_match_key(p text)
returns text
language sql
immutable
set search_path to 'pg_catalog','pg_temp'
as $fn$
  select coalesce(
    app.norm_phone(p),                                      -- SG number -> bare 8 digits
    nullif(regexp_replace(coalesce(p,''), '[^0-9]', '', 'g'), '')  -- else all digits
  );
$fn$;

-- ---------- WS2/WS4: portal client upsert (SG-dedup, intl passthrough) ----------
create or replace function app.upsert_portal_client(p_biz uuid, p_name text, p_phone text, p_email text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_client uuid; v_email text := nullif(trim(coalesce(p_email,'')),'');
begin
  select id into v_client from public.clients
   where business_id = p_biz
     and ( (app.phone_match_key(p_phone) is not null
            and app.phone_match_key(phone) = app.phone_match_key(p_phone))
        or (v_email is not null and email = v_email) )
   order by created_at
   limit 1;
  if v_client is null then
    insert into public.clients (business_id, full_name, phone, email)
    values (p_biz, trim(p_name), p_phone, v_email)
    on conflict (business_id, phone_norm) where phone_norm is not null do nothing
    returning id into v_client;
    if v_client is null then      -- lost the conflict race: fetch the row that won
      select id into v_client from public.clients
       where business_id = p_biz and phone_norm = app.norm_phone(p_phone)
       limit 1;
    end if;
  end if;
  return v_client;
end $fn$;

-- ---------- WS1: single source of truth for availability ----------
-- Pure POOL model: available = quantity - live holds (NOT partitioned by date).
-- A hold = a booking_request in ('new','pending') OR an appointment in ('booked')
-- that references this table type. 'confirmed' requests do NOT count (their linked
-- appointment is the hold -> no double count). security_invoker so member RLS scopes it.
create or replace view public.v_table_availability
with (security_invoker = true) as
select
  bt.business_id,
  bt.id   as table_type_id,
  bt.name, bt.pax, bt.quantity, bt.sort,
  h.held,
  greatest(bt.quantity - h.held, 0) as available
from public.booking_tables bt
cross join lateral (
  select (
      (select count(*) from public.booking_requests br
        where br.table_type_id = bt.id and br.status in ('new','pending'))
    + (select count(*) from public.appointments a
        where a.table_type_id = bt.id and a.status = 'booked')
  )::int as held
) h
where bt.active;

grant select on public.v_table_availability to authenticated;

-- ---------- WS5: realtime ----------
alter table public.notifications     replica identity full;
alter table public.booking_requests  replica identity full;
alter table public.appointments      replica identity full;

alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.booking_requests;
alter publication supabase_realtime add table public.appointments;