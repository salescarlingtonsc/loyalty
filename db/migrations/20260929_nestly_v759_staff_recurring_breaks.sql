-- nestly_v759 — a repeating break inside a team member's working day.
--
-- Owner, photo 1 (Appointments -> Block time -> Every week): under the weekly days off, "break
-- every week" — a start time, an end time (e.g. 12:00-13:00) and the weekdays it applies to.
-- Several breaks may exist per person. Customers never see the reason.
--
-- Two things ship here.
--
-- 1. public.staff_recurring_breaks. One row per (staff, weekday, window) — the shape
--    public.branch_breaks already uses, so a break means the same thing whether the shop declared
--    it or one person did, and every availability reader asks one question of one shape. A break
--    covering Monday..Friday is five rows, not a bitmask: every reader already filters on a
--    weekday column and nothing has to learn a second encoding. RLS, grants, index and the
--    (id, business_id) composite FK to public.staff mirror public.staff_recurring_off_days as
--    v383 created it and v602 hardened it.
--
-- 2. Both availability readers subtract it — the v432 rule that what staff see and what customers
--    are offered is ONE set of minutes:
--      * app.staff_free_for_appointment_v120_base, the WRITE-time guard, reached by
--        app.staff_free_for_appointment_v47 (v611) and suggest_appointment_staff_v47_v94_base, so
--        an appointment cannot be SAVED across somebody's lunch. The new clause sits immediately
--        after the existing branch_breaks clause and is its exact mirror, keyed on the same
--        extract(dow) weekday, so a Monday means the same thing in both.
--      * public.internal_public_booking_availability, the slot list the PUBLIC booking page draws.
--        It does not call the guard, so a break honoured only in the guard would still be OFFERED
--        to a stranger and refused afterwards at save time.
--
-- The browser calendar (app/app.js recordedSchedule) draws these breaks alongside the branch's, so
-- all three readers agree.
--
-- Rollback: db/tests/v759_staff_recurring_breaks.sql

begin;


-- ----------------------------------------------------------------- public.staff_recurring_breaks
create table if not exists public.staff_recurring_breaks(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null,
  created_at timestamptz not null default now(),
  constraint staff_recurring_breaks_window_check check (ends_at > starts_at),
  constraint staff_recurring_breaks_staff_business_fkey
    foreign key (staff_id, business_id) references public.staff (id, business_id) on delete cascade,
  unique (business_id, staff_id, weekday, starts_at, ends_at)
);
comment on table public.staff_recurring_breaks is
  'v759 A team member''s recurring weekly break inside the working day (lunch, a standing
   commitment). weekday uses extract(dow) — 0 = Sunday — the same convention branch_hours,
   staff_hours, branch_breaks and staff_recurring_off_days already use, so every availability
   reader asks the same question. A break covering several weekdays is one row per weekday.';

alter table public.staff_recurring_breaks enable row level security;

-- Policies mirror staff_recurring_off_days exactly: members read, the owner writes, super admin reads.
drop policy if exists staff_recurring_breaks_select on public.staff_recurring_breaks;
create policy staff_recurring_breaks_select on public.staff_recurring_breaks
  for select to authenticated using (app.is_salon_member(business_id));
drop policy if exists staff_recurring_breaks_write on public.staff_recurring_breaks;
create policy staff_recurring_breaks_write on public.staff_recurring_breaks
  for all to authenticated using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
drop policy if exists staff_recurring_breaks_sa_read on public.staff_recurring_breaks;
create policy staff_recurring_breaks_sa_read on public.staff_recurring_breaks
  for select to authenticated using (app.is_super_admin());

grant select, insert, update, delete on public.staff_recurring_breaks to authenticated;
grant all on public.staff_recurring_breaks to postgres, service_role;

create index if not exists staff_recurring_breaks_lookup
  on public.staff_recurring_breaks (business_id, staff_id, weekday);


-- --------------------------------------------- app.staff_free_for_appointment_v120_base
-- Restated verbatim from db/migrations/20260817_nestly_v383_off_days_block_bookings.sql with ONE
-- addition: the staff_recurring_breaks clause after the branch_breaks clause.
CREATE OR REPLACE FUNCTION app.staff_free_for_appointment_v120_base(p_business uuid, p_staff uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_ends timestamp with time zone, p_exclude_appointment uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_timezone text;
  v_buffer_before integer := 0;
  v_buffer_after integer := 0;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_weekday smallint;
begin
  if p_business is null or p_staff is null or p_branch is null
     or p_starts is null or p_ends is null or p_ends <= p_starts then
    return false;
  end if;

  select b.timezone into v_timezone
    from public.branches b
   where b.id = p_branch and b.business_id = p_business and b.active;
  if not found then return false; end if;

  if p_service is not null then
    select service.buffer_before_min, service.buffer_after_min
      into v_buffer_before, v_buffer_after
      from public.services service
     where service.id = p_service and service.business_id = p_business and service.active;
    if not found then return false; end if;
  end if;

  v_block_start := p_starts - make_interval(mins => v_buffer_before);
  v_block_end := p_ends + make_interval(mins => v_buffer_after);
  v_local_start := v_block_start at time zone v_timezone;
  v_local_end := v_block_end at time zone v_timezone;
  v_weekday := extract(dow from v_local_start)::smallint;

  if v_local_end::date <> v_local_start::date then return false; end if;

  if not exists (
    select 1
      from public.staff s
      join public.staff_branches sb
        on sb.business_id = s.business_id and sb.staff_id = s.id
       and sb.branch_id = p_branch
     where s.id = p_staff and s.business_id = p_business and s.active
  ) then return false; end if;

  if p_service is not null
     and exists (
       select 1 from public.staff_services configured
        where configured.business_id = p_business
          and configured.service_id = p_service
     )
     and not exists (
       select 1 from public.staff_services qualified
        where qualified.business_id = p_business
          and qualified.staff_id = p_staff
          and qualified.service_id = p_service
     ) then return false; end if;

  if exists (
    select 1 from public.staff_off_days off_day
     where off_day.business_id = p_business and off_day.staff_id = p_staff
       and v_local_start::date between off_day.starts_on and off_day.ends_on
  ) then return false; end if;

  -- v383: a recurring weekly off day. Same refusal as a one-off, keyed on the SAME weekday
  -- expression (extract(dow ...), 0 = Sunday) the branch and staff hour rules above already use.
  if exists (
    select 1 from public.staff_recurring_off_days recurring
     where recurring.business_id = p_business and recurring.staff_id = p_staff
       and recurring.weekday = v_weekday
  ) then return false; end if;

  -- Legacy workspaces may not have configured opening hours. Once any row exists
  -- for this weekday, the service plus its buffers must fit inside an opening row.
  if exists (
    select 1 from public.branch_hours configured
     where configured.business_id = p_business and configured.branch_id = p_branch
       and configured.weekday = v_weekday
  ) and not exists (
    select 1 from public.branch_hours hours
     where hours.business_id = p_business and hours.branch_id = p_branch
       and hours.weekday = v_weekday
       and v_local_start::time >= hours.opens_at
       and v_local_end::time <= hours.closes_at
  ) then return false; end if;

  if exists (
    select 1 from public.branch_breaks pause
     where pause.business_id = p_business and pause.branch_id = p_branch
       and pause.weekday = v_weekday
       and pause.starts_at < v_local_end::time
       and pause.ends_at > v_local_start::time
  ) then return false; end if;

  -- v759: this team member's OWN repeating break. Exact mirror of the shop's break clause above,
  -- keyed on the same weekday, so a booking cannot be saved across somebody's lunch.
  if exists (
    select 1 from public.staff_recurring_breaks pause
     where pause.business_id = p_business and pause.staff_id = p_staff
       and pause.weekday = v_weekday
       and pause.starts_at < v_local_end::time
       and pause.ends_at > v_local_start::time
  ) then return false; end if;

  -- Existing firms did not always configure staff hours. Preserve availability in that
  -- case, but once a weekday row exists the complete appointment must fit inside it.
  if exists (
    select 1 from public.staff_hours configured
     where configured.business_id = p_business and configured.staff_id = p_staff
       and configured.weekday = v_weekday
  ) and not exists (
    select 1 from public.staff_hours hours
     where hours.business_id = p_business and hours.staff_id = p_staff
       and hours.weekday = v_weekday
       and v_local_start::time >= hours.starts_at
       and v_local_end::time <= hours.ends_at
  ) then return false; end if;

  if exists (
    select 1
      from public.appointments existing
      left join public.services existing_service
        on existing_service.id = existing.service_id
       and existing_service.business_id = existing.business_id
     where existing.business_id = p_business
       and existing.staff_id = p_staff
       and existing.status = 'booked'
       and existing.id is distinct from p_exclude_appointment
       and (
         existing.starts_at - make_interval(mins => coalesce(existing_service.buffer_before_min,0))
       ) < v_block_end
       and (
         existing.ends_at + make_interval(mins => coalesce(existing_service.buffer_after_min,0))
       ) > v_block_start
  ) then return false; end if;

  return true;
end
$function$;

-- Grants restated from the LAST migration that set them — db/migrations/20260829_nestly_v599_
-- browser_write_boundaries.sql, not v383, which created the function and granted `authenticated`.
-- v599 took that grant away: no browser role may probe the booking guard directly, only the
-- SECURITY DEFINER callers above it. Restating v383's wider line here would silently re-widen the
-- surface (caught by db/tests/executed/v720_corpus_evidence_pack_grants.sql, which allowlists the
-- app functions reachable from anon/authenticated).
revoke execute on function app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) from public, anon, authenticated;
grant execute on function app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) to postgres, service_role;


-- ------------------------------------------- public.internal_public_booking_availability
-- Restated verbatim from db/migrations/20260829_nestly_v598_shop_hours_are_the_default.sql with
-- ONE addition: the staff_recurring_breaks exclusion in the `free` CTE.
CREATE OR REPLACE FUNCTION public.internal_public_booking_availability(p_slug text, p_service uuid, p_staff uuid, p_from date, p_days integer, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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

  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
     where branch_row.id = p_branch
       and branch_row.business_id = v_business.id
       and branch_row.active
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
    from app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) bookable;

  v_hours_configured := exists (
    select 1 from public.staff_hours hours
     join app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) bookable
       on bookable.staff_id = hours.staff_id
     where hours.business_id = v_business.id
  ) or exists (
    select 1 from public.branch_hours hours
     join public.branches branch_row
       on branch_row.id = hours.branch_id
      and branch_row.business_id = v_business.id
     where hours.business_id = v_business.id
       and (p_branch is null or branch_row.id = p_branch)
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
    select calendar.day,
           member.staff_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar
      cross join app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) member
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
           and (p_branch is null or branch_row.id = p_branch)
         order by branch_row.is_default desc nulls last, branch_row.created_at, branch_row.id
         limit 1
      -- nestly_v598 (owner ruling 2026-08-29): "all employees will work on everyday of the
      -- working hours - until the owner block the employees schedule."
      -- This join used to be gated on the teammate having NO staff_hours row ANYWHERE, so a
      -- rota covering Mon-Sat silently made Sunday unbookable even after the shop opened on
      -- Sunday: own.starts_at was null for weekday 0, the branch row was never joined, and the
      -- `is not null` filter below dropped the day. The shop's hours are now the default for
      -- every open weekday and a personal row is an OVERRIDE for the weekday it names.
      -- Being unavailable is stated, not inferred: public.staff_recurring_off_days (a weekly day
      -- off) and public.staff_off_days (a date range) are both refused in the WHERE clause below,
      -- and blocked times are refused by the slot filter further down.
      ) branch on true
     where coalesce(own.starts_at, branch.opens_at) is not null
       and coalesce(own.ends_at, branch.closes_at) is not null
       -- v383: the public booking page never honoured off days at all — this function does not
       -- call staff_free_for_appointment, so a team member marked off was still offered slots to
       -- strangers. Both kinds are refused here, on the same weekday expression used above.
       and not exists (
         select 1 from public.staff_off_days off_day
          where off_day.business_id = v_business.id and off_day.staff_id = member.staff_id
            and calendar.day between off_day.starts_on and off_day.ends_on
       )
       and not exists (
         select 1 from public.staff_recurring_off_days recurring
          where recurring.business_id = v_business.id and recurring.staff_id = member.staff_id
            and recurring.weekday = extract(dow from calendar.day)::smallint
       )
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
       -- v759: a repeating break is subtracted here, not in the window above, because it cuts a
       -- hole in the middle of a working day rather than shortening it. The same overlap test the
       -- write-time guard applies, so what a customer is OFFERED is what can be SAVED.
       and not exists (
         select 1 from public.staff_recurring_breaks pause
          where pause.business_id = v_business.id
            and pause.staff_id = slots.staff_id
            and pause.weekday = extract(dow from slots.day)::smallint
            and tstzrange(timezone('Asia/Singapore', (slots.day + pause.starts_at)::timestamp),
                          timezone('Asia/Singapore', (slots.day + pause.ends_at)::timestamp), '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
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
       and not exists (
         select 1 from public.booking_requests pending
         left join public.services pending_service
           on pending_service.id = pending.service_id
          and pending_service.business_id = v_business.id
          where pending.business_id = v_business.id
            and pending.staff_id = slots.staff_id
            and pending.status in ('new', 'pending', 'waitlisted')
            and pending.preferred_at is not null
            and tstzrange(pending.preferred_at,
                          pending.preferred_at + make_interval(mins => greatest(
                            coalesce(pending_service.duration_min, 60)
                              + coalesce(pending_service.buffer_before_min, 0)
                              + coalesce(pending_service.buffer_after_min, 0),
                            5)),
                          '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
  ), per_slot as (
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
$function$;

comment on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) is
  'nestly_v759: the branch row is the default working window for every open weekday; a staff_hours '
  'row overrides it for the weekday it names. Unavailability is stated through '
  'staff_recurring_off_days (weekly), staff_off_days (a date range), staff_recurring_breaks (a '
  'weekly break inside the working day) or a blocked time — never inferred from a missing row.';

-- Grants restated verbatim from db/migrations/20260829_nestly_v598_shop_hours_are_the_default.sql.
-- This function is internal: it is reached only by the Turnstile-gated public gateway running as
-- service_role, and no browser role may execute it.
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) from public, anon, authenticated;
grant execute on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) to service_role;

commit;
