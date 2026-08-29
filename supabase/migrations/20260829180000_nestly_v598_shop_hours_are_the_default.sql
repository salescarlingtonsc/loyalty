-- nestly_v598 — the shop's opening hours are every teammate's default working hours.
--
-- OWNER RULING (2026-08-29): "all employees will work on everyday of the working hours - until
-- the owner 'block' the employees schedule. if no employee is available then no booking is
-- available. but in this case, there is working hours on sunday, employees are not blocked on
-- sunday - it should be able to select the employees accordingly."
--
-- THE BUG, measured on production. Cubbly SPA opened Cubbly · Orchard on Sunday: branch_hours
-- carries weekday 0 (10:00-19:00), exactly as saved. Its three bookable staff carry staff_hours
-- for weekdays 1-6 and none for 0. internal_public_booking_availability joined the branch row
-- only `on not exists (select 1 from staff_hours any_row where ... staff_id = member.staff_id)`
-- — that is, only for a teammate with NO personal hours AT ALL. All three have Mon-Sat rows, so
-- for Sunday own.starts_at was null, the branch was never joined, and `where coalesce(...) is not
-- null` dropped the day. The shop was open, nobody was blocked, and customers were offered zero
-- Sunday slots. The owner's own Appointments calendar said "Working hours not set", which reads
-- as "your setting did not save" rather than "nobody works that day".
--
-- THE CHANGE. One join condition: `branch on true`. The window becomes
-- coalesce(own.starts_at, branch.opens_at) PER WEEKDAY — a personal row overrides the shop for
-- the weekday it names, and every other open weekday falls back to the shop's hours. Everything
-- else in this function is preserved byte for byte, including the v383 refusals this depends on.
--
-- WHY NO BACKFILL. Under the old rule a missing weekday MEANT "off", so turning that into
-- "works shop hours" could make somebody bookable on a day they were deliberately left off. That
-- was measured across all of production before writing this, per weekday per business, over
-- active + customer_bookable staff who have any rota at all:
--     partial gaps (some staff cover a weekday, others do not) : 0
--     universal gaps (nobody covers a weekday)                 : 1   <- Cubbly's Sunday
-- Not one tenant has ever expressed a per-person weekly day off through row absence. A universal
-- gap is not a rota decision, it is a day the shop was not open. So no row anywhere changes
-- meaning, nothing anyone has set is lost, and no backfill is written. The explicit statement
-- already exists and is what the owner keeps: public.staff_recurring_off_days (v383), which this
-- function already refuses and which the roster editor now writes when a day is ticked Closed.
--
-- Rollback: db/tests/v598_shop_hours_are_the_default.sql

begin;

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
  'nestly_v598: the branch row is the default working window for every open weekday; a staff_hours '
  'row overrides it for the weekday it names. Unavailability is stated through '
  'staff_recurring_off_days (weekly), staff_off_days (a date range) or a blocked time — never '
  'inferred from a missing row.';

-- Grants restated verbatim from the live proacl (postgres=X, service_role=X). This function is
-- internal: it is reached only by the Turnstile-gated public gateway running as service_role, and
-- no browser role may execute it.
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) from public, anon, authenticated;
grant execute on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) to service_role;

commit;
