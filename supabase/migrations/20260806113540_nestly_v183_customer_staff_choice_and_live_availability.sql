-- v183 — customer-chosen team member + live booking availability
--
-- Owner directive (2026-08-06, annotated booking screenshots):
--   "if services allow customers to choose staff - please enable it - then live sync the
--    calendar to facilitate (so will show available timings of staff) - business and this
--    customer end will be sync. if staff is not worth please allow toggle in business and
--    show in customer portal. business still will approve/reject the appointment."
--
-- Design notes
--  * The customer-facing team step used to be an honest fake: a free-text "who would you
--    like" that rode along in the booking notes. It is replaced by real, server-validated
--    staff identities and by real availability derived from the SAME rows the business
--    calendar reads (staff_hours / branch_hours / appointments / staff_blocked_times), so
--    the two ends cannot drift.
--  * Staff choice is OFF by default. A business that does not want customers picking a
--    person keeps the shorter flow, and no staff identity is exposed on the public page.
--  * Availability is advisory, never a hold. The business still approves or rejects: this
--    changes what a customer is shown, not who decides. A slot that is free at 10:00:03
--    can be taken by the counter at 10:00:04 and the request will simply be declined.
--  * Weekday convention is Postgres `extract(dow)`: 0 = Sunday … 6 = Saturday, matching the
--    existing branch_hours/staff_hours CHECK (weekday between 0 and 6).
--  * Everything runs in Asia/Singapore. The platform is Singapore-first and every other
--    booking surface already anchors to +08:00.

begin;

-- 1. Business-level switch and per-staff opt-out ------------------------------------------
alter table public.businesses
  add column if not exists booking_staff_choice boolean not null default false;
comment on column public.businesses.booking_staff_choice is
  'v183: when true the public booking page lets a customer choose a specific team member.';

alter table public.staff
  add column if not exists customer_bookable boolean not null default true;
comment on column public.staff.customer_bookable is
  'v183: false hides this team member from the customer-facing booking page. Rota-only and
   back-office people should be false; it has no effect while businesses.booking_staff_choice
   is false.';

-- 2. Carry the chosen team member on the request and the auto-confirmed appointment --------
alter table public.booking_requests
  add column if not exists staff_id uuid;
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.booking_requests'::regclass
       and conname = 'booking_requests_staff_id_fkey'
  ) then
    alter table public.booking_requests
      add constraint booking_requests_staff_id_fkey
      foreign key (staff_id) references public.staff(id) on delete set null;
  end if;
end $$;
comment on column public.booking_requests.staff_id is
  'v183: the team member the CUSTOMER asked for. The business remains free to assign someone
   else when it approves the request.';

-- 3. Bookable-staff resolver ----------------------------------------------------------------
-- One definition of "who can a customer ask for", shared by the page projection, the
-- availability engine and the submit validator so they cannot disagree.
create or replace function app.v183_bookable_staff(
  p_business uuid, p_service uuid, p_staff uuid
) returns table (staff_id uuid, full_name text, title text)
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select member.id,
         coalesce(nullif(btrim(member.full_name), ''), 'Team member'),
         nullif(btrim(member.title), '')
    from public.staff member
   where member.business_id = p_business
     and coalesce(member.active, true)
     and coalesce(member.customer_bookable, true)
     and (p_staff is null or member.id = p_staff)
     -- A service with no explicit assignments is offered by everyone; once the business
     -- assigns anyone, only the assigned people are offered.
     and (
       p_service is null
       or not exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = p_business and mapped.service_id = p_service
       )
       or exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = p_business
            and mapped.service_id = p_service
            and mapped.staff_id = member.id
       )
     );
$$;

revoke all on function app.v183_bookable_staff(uuid, uuid, uuid) from public;
revoke all on function app.v183_bookable_staff(uuid, uuid, uuid) from anon;
revoke all on function app.v183_bookable_staff(uuid, uuid, uuid) from authenticated;

-- 4. Availability engine -------------------------------------------------------------------
-- Resolves the bookable staff set for a service, then subtracts booked appointments and
-- blocked time from each person''s working window. Returns whole slots only — a slot is
-- offered only when the entire service (including its buffers) fits inside a free window.
create or replace function public.internal_public_booking_availability(
  p_slug text,
  p_service uuid,
  p_staff uuid,
  p_from date,
  p_days integer
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business public.businesses%rowtype;
  v_duration integer;
  v_days integer := least(greatest(coalesce(p_days, 7), 1), 14);
  v_from date := greatest(coalesce(p_from, (statement_timestamp() at time zone 'Asia/Singapore')::date),
                          (statement_timestamp() at time zone 'Asia/Singapore')::date);
  v_hours_configured boolean;
  v_staff jsonb;
  v_days_out jsonb;
  v_earliest timestamptz := statement_timestamp() + interval '15 minutes';
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
    return null;
  end if;

  select business.* into v_business
    from public.businesses business
   where business.slug = p_slug
   limit 1;
  if not found then
    return null;
  end if;

  -- Staff choice off => the customer never sees per-person availability, and the portal keeps
  -- its plain "preferred time" request. Fail closed rather than leaking the roster.
  if coalesce(v_business.booking_staff_choice, false) is not true then
    return jsonb_build_object(
      'staff_choice', false, 'hours_configured', false,
      'slot_minutes', 30, 'staff', '[]'::jsonb, 'days', '[]'::jsonb
    );
  end if;

  if p_service is not null and not exists (
    select 1 from public.services service
     where service.id = p_service
       and service.business_id = v_business.id
       and service.active
       and service.show_on_booking_page
  ) then
    return null;
  end if;

  select coalesce(service.duration_min, 60)
       + coalesce(service.buffer_before_min, 0)
       + coalesce(service.buffer_after_min, 0)
    into v_duration
    from public.services service
   where service.id = p_service
     and service.business_id = v_business.id;
  v_duration := greatest(coalesce(v_duration, 60), 5);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', bookable.staff_id, 'name', bookable.full_name, 'title', bookable.title
         ) order by lower(bookable.full_name), bookable.staff_id), '[]'::jsonb)
    into v_staff
    from app.v183_bookable_staff(v_business.id, p_service, p_staff) bookable;

  v_hours_configured := exists (
    select 1 from public.staff_hours hours
     join app.v183_bookable_staff(v_business.id, p_service, p_staff) bookable
       on bookable.staff_id = hours.staff_id
     where hours.business_id = v_business.id
  ) or exists (
    select 1 from public.branch_hours hours where hours.business_id = v_business.id
  );

  if not v_hours_configured or v_staff = '[]'::jsonb then
    return jsonb_build_object(
      'staff_choice', true,
      'hours_configured', v_hours_configured,
      'slot_minutes', 30,
      'staff', v_staff,
      'days', '[]'::jsonb
    );
  end if;

  with calendar as (
    select (v_from + offset_days)::date as day
      from generate_series(0, v_days - 1) as offset_days
  ), windows as (
    -- Per-person working window for that weekday: their own rota if they have one at all,
    -- otherwise the branch opening hours. A person WITH a rota who is not rostered that day
    -- has no window, which is the point of a rota.
    select calendar.day,
           member.staff_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar
      cross join app.v183_bookable_staff(v_business.id, p_service, p_staff) member
      left join public.staff_hours own
        on own.business_id = v_business.id
       and own.staff_id = member.staff_id
       and own.weekday = extract(dow from calendar.day)::smallint
      left join lateral (
        select hours.opens_at, hours.closes_at
          from public.branch_hours hours
          join public.branches branch_row
            on branch_row.id = hours.branch_id
           and branch_row.business_id = v_business.id
           and coalesce(branch_row.active, true)
         where hours.business_id = v_business.id
           and hours.weekday = extract(dow from calendar.day)::smallint
         order by branch_row.is_default desc nulls last, branch_row.created_at, branch_row.id
         limit 1
      ) branch on not exists (
        select 1 from public.staff_hours any_row
         where any_row.business_id = v_business.id and any_row.staff_id = member.staff_id
      )
     where coalesce(own.starts_at, branch.opens_at) is not null
       and coalesce(own.ends_at, branch.closes_at) is not null
  ), slots as (
    select windows.day,
           windows.staff_id,
           slot_at
      from windows
      cross join lateral generate_series(
        timezone('Asia/Singapore', (windows.day + windows.starts_at)::timestamp),
        timezone('Asia/Singapore', (windows.day + windows.ends_at)::timestamp) - make_interval(mins => v_duration),
        interval '30 minutes'
      ) as slot_at
  ), free as (
    select slots.day, slots.staff_id, slots.slot_at
      from slots
     where slots.slot_at >= v_earliest
       and not exists (
         select 1 from public.appointments booked
          where booked.business_id = v_business.id
            and booked.staff_id = slots.staff_id
            and booked.status not in ('cancelled', 'no_show', 'declined')
            and tstzrange(booked.starts_at,
                          coalesce(booked.ends_at, booked.starts_at + interval '1 hour'), '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
       and not exists (
         select 1 from public.staff_blocked_times blocked
          where blocked.business_id = v_business.id
            and blocked.staff_id = slots.staff_id
            and tstzrange(blocked.starts_at, blocked.ends_at, '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
  ), per_slot as (
    -- One row per distinct time. staff_ids lets the portal offer "anyone available" without a
    -- second round trip, and lets it name who it will ask for when the customer picked a person.
    select free.day,
           free.slot_at,
           jsonb_agg(free.staff_id order by free.staff_id) as staff_ids
      from free
     group by free.day, free.slot_at
  )
  select coalesce(jsonb_agg(day_row order by day_row->>'date'), '[]'::jsonb)
    into v_days_out
    from (
      select jsonb_build_object(
               'date', to_char(per_slot.day, 'YYYY-MM-DD'),
               'slots', jsonb_agg(jsonb_build_object(
                 'at', per_slot.slot_at,
                 'staff_ids', per_slot.staff_ids
               ) order by per_slot.slot_at)
             ) as day_row
        from per_slot
       group by per_slot.day
    ) grouped;

  return jsonb_build_object(
    'staff_choice', true,
    'hours_configured', true,
    'slot_minutes', 30,
    'duration_minutes', v_duration,
    'staff', v_staff,
    'days', coalesce(v_days_out, '[]'::jsonb)
  );
exception when others then
  return null;
end;
$$;

revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer) from public;
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer) from anon;
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer) from authenticated;
grant execute on function public.internal_public_booking_availability(text, uuid, uuid, date, integer) to service_role;

-- 5. Booking page projection ---------------------------------------------------------------
-- get_business_public() is left untouched (other callers depend on its exact shape); the
-- gateway-only wrapper is what gains the booking flags and the bookable roster.
create or replace function public.internal_public_booking_page(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_page jsonb;
  v_business public.businesses%rowtype;
  v_staff jsonb := '[]'::jsonb;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
    return null;
  end if;

  select public.get_business_public(p_slug)::jsonb into v_page;
  if v_page is null then
    return null;
  end if;

  select business.* into v_business
    from public.businesses business
   where business.slug = p_slug
   limit 1;
  if not found then
    return null;
  end if;

  if coalesce(v_business.booking_staff_choice, false) then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', member.id,
             'name', coalesce(nullif(btrim(member.full_name), ''), 'Team member'),
             'title', nullif(btrim(member.title), ''),
             'service_ids', coalesce((
               select jsonb_agg(mapped.service_id order by mapped.service_id)
                 from public.staff_services mapped
                where mapped.business_id = v_business.id
                  and mapped.staff_id = member.id
             ), '[]'::jsonb)
           ) order by lower(coalesce(member.full_name, '')), member.id), '[]'::jsonb)
      into v_staff
      from public.staff member
     where member.business_id = v_business.id
       and coalesce(member.active, true)
       and coalesce(member.customer_bookable, true);
  end if;

  return v_page || jsonb_build_object(
    'booking_auto_confirm', coalesce(v_business.booking_auto_confirm, false),
    'booking_staff_choice', coalesce(v_business.booking_staff_choice, false),
    'staff', v_staff
  );
exception when others then
  return null;
end;
$$;

revoke all on function public.internal_public_booking_page(text) from public;
revoke all on function public.internal_public_booking_page(text) from anon;
revoke all on function public.internal_public_booking_page(text) from authenticated;
grant execute on function public.internal_public_booking_page(text) to service_role;

-- 6. Submit: validate and record the requested team member ---------------------------------
create or replace function public.internal_public_booking_submit(
  p_slug text, p_name text, p_email text, p_phone text, p_service uuid,
  p_party integer, p_preferred timestamptz, p_notes text, p_table_type uuid,
  p_consent boolean, p_token_hash text, p_idempotency_hash text,
  p_request_fingerprint text, p_authenticated_user uuid, p_staff uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business_id uuid;
  v_result jsonb;
  v_request uuid;
  v_appointment uuid;
begin
  -- The staff preference is validated BEFORE the shared submit path runs, so an invalid or
  -- foreign staff id is rejected outright rather than silently dropped.
  if p_staff is not null then
    select business.id into v_business_id
      from public.businesses business
     where business.slug = p_slug
     limit 1;
    if v_business_id is null then
      raise exception 'invalid request' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.businesses business
       where business.id = v_business_id
         and coalesce(business.booking_staff_choice, false)
    ) or not exists (
      select 1 from public.staff member
       where member.id = p_staff
         and member.business_id = v_business_id
         and coalesce(member.active, true)
         and coalesce(member.customer_bookable, true)
    ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
    if p_service is not null
       and exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = v_business_id and mapped.service_id = p_service
       )
       and not exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = v_business_id
            and mapped.service_id = p_service
            and mapped.staff_id = p_staff
       ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
  end if;

  select public.internal_public_booking_submit(
    p_slug, p_name, p_email, p_phone, p_service, p_party, p_preferred,
    p_notes, p_table_type, p_consent, p_token_hash, p_idempotency_hash,
    p_request_fingerprint, p_authenticated_user
  ) into v_result;

  if p_staff is null or v_result is null or coalesce((v_result->>'conflict')::boolean, false)
     or coalesce((v_result->>'replayed')::boolean, false) then
    return v_result;
  end if;

  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;

  if v_request is not null then
    update public.booking_requests
       set staff_id = p_staff
     where id = v_request
       and business_id = v_business_id;
  end if;
  -- An auto-confirmed booking becomes an appointment immediately; the request is what the
  -- customer asked for, so the assignment is only applied when the slot is still unassigned.
  if v_appointment is not null then
    update public.appointments
       set staff_id = p_staff
     where id = v_appointment
       and business_id = v_business_id
       and staff_id is null;
  end if;

  return v_result;
end;
$$;

revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid
) from public;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid
) from anon;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid
) from authenticated;
grant execute on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid
) to service_role;

commit;
