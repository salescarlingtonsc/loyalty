-- nestly_v991 — a shop with no opening hours can take a booking again (2026-09-16).
--
-- OWNER, 2026-09-16: "continue testing until the business view is 100/100 fully tested and bugs free.
-- with no more issues, business owner will not keep coming to me to fix".
--
-- THE DEFECT, proven against production, rolled back, one variable changed:
--
--   tenant QA Test Cafe, same staff member, same branch, same Wednesday 10:00-11:00 slot
--     app.staff_free_for_appointment_v47 with NO branch_hours rows      -> false   (cannot book)
--     the same call after inserting branch_hours 09:00-18:00            -> true
--
-- A business that has not filled in its opening hours cannot book ANY appointment, with any staff
-- member, at any time. On this estate that is 18 of 24 businesses, and 16 of those 18 have never
-- managed to create a single appointment. Opening hours are not part of the go-live checklist, so a
-- new merchant reaches the Appointments page in exactly this state.
--
-- WHY IT HAPPENS. app.staff_free_for_appointment_v47 carried a bare
--
--     or not exists (select 1 from public.branch_hours hours where ... within hours)
--
-- with no test for whether any hours are configured at all. "No row matches" and "no rows exist"
-- are the same answer to that predicate, so an unconfigured branch is treated as a permanently
-- closed one.
--
-- It is the only copy that got it wrong, which is what makes it a copy bug rather than a design
-- decision:
--   * the staff_hours arm FOUR LINES BELOW it in the same function is already written as
--     `exists(configured) and not exists(within)`;
--   * app.staff_free_for_appointment_v120_base -- which v47 calls FIRST, before this arm -- already
--     guards branch_hours the same way. The guarded answer is computed and then overruled.
-- nestly_v611 recorded the ruling ("the write-time booking guard honours the shop-hours default")
-- and nestly_v598 the same for staff. v47 was simply never brought along.
--
-- THE BLAST RADIUS IS EVERY BOOKING PATH, because every caller uses v47 and none uses the guarded
-- base directly:
--   public.book_appointment_smart_v47_v94_base      (the merchant's New appointment)
--   public.reschedule_appointment_v48_v94_base      (reschedule)
--   public.suggest_appointment_staff_v47_v94_base   ("who else is free?")
--   public.decide_change
--   app.guard_staff_blocked_time_v120
--   app.suggest_appointment_reschedule_v48
--   app.v660_autoapprove_booking_request            (so a customer portal request cannot auto-approve)
--
-- WHAT THIS CHANGES, precisely: a branch with NO hours row for that weekday stops being treated as
-- closed. A branch that DOES have hours for that weekday is unaffected -- the restriction still
-- applies, unchanged. This can only ever widen availability, and only for a weekday nobody has
-- described, so it cannot make an already-bookable slot unbookable.
--
-- NOT CHANGED HERE, deliberately: the refusal MESSAGE. When a booking is refused the merchant is
-- told "<Staff name> is already busy then" / "Nobody else is free at this time either", which was
-- false in exactly this case and is the reason the cause was invisible for so long. That is app-side
-- copy, it belongs with the Appointments UI rather than in a booking-guard migration, and it is
-- filed separately.
--
-- Rollback suite: db/tests/v991_no_hours_does_not_mean_closed.sql

begin;

do $v991_assert$
declare v_body text := pg_get_functiondef('app.staff_free_for_appointment_v47(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)'::regprocedure);
begin
  if position('nestly_v991' in v_body) > 0 then
    raise exception 'v991: staff_free_for_appointment_v47 already carries v991';
  end if;
  /* the exact unguarded predicate this migration replaces must still be there */
  if position('or not exists (
       select 1 from public.branch_hours hours' in v_body) = 0 then
    raise exception 'v991: the unguarded branch_hours arm is not where this migration expects it';
  end if;
end
$v991_assert$;

CREATE OR REPLACE FUNCTION app.staff_free_for_appointment_v47(p_business uuid, p_staff uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_ends timestamp with time zone, p_exclude_appointment uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_buffer_before integer:=0;
  v_buffer_after integer:=0;
  v_timezone text;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_weekday smallint;
begin
  if not app.staff_free_for_appointment_v120_base(
    p_business,p_staff,p_branch,p_service,p_starts,p_ends,p_exclude_appointment
  ) then
    return false;
  end if;

  if p_service is not null then
    -- nestly_v884: a service or a bundle (summed buffers), through the one resolver.
    select item.buffer_before_min,item.buffer_after_min
      into v_buffer_before,v_buffer_after
      from app.booking_item_v884(p_business,p_service) item;
    if not found then return false; end if;
  end if;

  select branch.timezone into v_timezone
    from public.branches branch
   where branch.business_id=p_business and branch.id=p_branch and branch.active;
  if not found then return false; end if;
  v_block_start:=p_starts-make_interval(mins=>coalesce(v_buffer_before,0));
  v_block_end:=p_ends+make_interval(mins=>coalesce(v_buffer_after,0));
  v_local_start:=v_block_start at time zone v_timezone;
  v_local_end:=v_block_end at time zone v_timezone;
  v_weekday:=extract(dow from v_local_start)::smallint;

  if v_local_end::date<>v_local_start::date
     or (
       /* nestly_v991: shop hours restrict a booking only where shop hours EXIST. This arm used to be
          a bare `not exists (... within hours)`, so a branch with no branch_hours row for that
          weekday failed it every time and NOBODY was ever free -- 18 of 24 businesses on this estate
          had no branch_hours row at all. The guard below is the same shape this function already
          uses for staff_hours four lines down, and the same shape app.staff_free_for_appointment_v120_base
          (which this function delegates to first) already uses for branch_hours. v47 was the one
          copy that never got it. */
       exists (
         select 1 from public.branch_hours hours
          where hours.business_id=p_business and hours.branch_id=p_branch
            and hours.weekday=v_weekday
       )
       and not exists (
         select 1 from public.branch_hours hours
          where hours.business_id=p_business and hours.branch_id=p_branch
            and hours.weekday=v_weekday
            and v_local_start::time>=hours.opens_at
            and v_local_end::time<=hours.closes_at
       )
     )
     or (
       exists (
         select 1 from public.staff_hours hours
          where hours.business_id=p_business and hours.staff_id=p_staff
            and hours.weekday=v_weekday
       )
       and not exists (
         select 1 from public.staff_hours hours
          where hours.business_id=p_business and hours.staff_id=p_staff
            and hours.weekday=v_weekday
            and v_local_start::time>=hours.starts_at
            and v_local_end::time<=hours.ends_at
       )
     ) then
    return false;
  end if;

  return not exists (
    select 1 from public.staff_blocked_times blocked
     where blocked.business_id=p_business and blocked.staff_id=p_staff
       and blocked.starts_at < v_block_end
       and blocked.ends_at > v_block_start
  );
end
$function$;


do $v991_verify$
declare
  v_biz uuid; v_branch uuid; v_staff uuid; v_start timestamptz; v_end timestamptz; v_free boolean;
begin
  /* A branch with no hours at all must now be bookable. Measured on a real tenant, then left alone —
     this reads and calls, it writes nothing. */
  select b.id, br.id, s.id into v_biz, v_branch, v_staff
    from public.businesses b
    join public.branches br on br.business_id=b.id and br.active
    join public.staff s on s.business_id=b.id and s.active
    join public.staff_branches sb on sb.business_id=b.id and sb.staff_id=s.id and sb.branch_id=br.id
   where not exists (select 1 from public.branch_hours h where h.branch_id=br.id)
   limit 1;
  if v_biz is null then return; end if;   /* nothing to assert against; not a failure */

  v_start := (date_trunc('week', now() at time zone 'Asia/Singapore')::date + 9 + time '10:00') at time zone 'Asia/Singapore';
  v_end := v_start + interval '1 hour';
  v_free := app.staff_free_for_appointment_v47(v_biz, v_staff, v_branch, null, v_start, v_end, null);
  if not v_free then
    raise exception 'v991: a branch with no opening hours is still unbookable';
  end if;
end
$v991_verify$;

commit;
