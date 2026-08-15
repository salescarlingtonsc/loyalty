-- v329 — owner-side booking-request reschedule (Day-view "Change time")
--
-- Owner directive (2026-08-15, business Appointments app): a booking made with a specific
-- team member selected should pop up asking the owner to confirm or check availability;
-- "check availability" should land on the Day calendar already on that date/team member with
-- the pending request highlighted, letting the owner confirm, change the time, or decline
-- right there; and a persistent top-right reminder should stay visible while anything is
-- unconfirmed.
--
-- The pop-up, the persistent badge and the Day-view banner are entirely client-side, reading
-- booking_requests (already selectable by 'bookings' read access) and reusing the existing
-- staff_decide_booking_request_v73 confirm/decline path unchanged. The ONE new server surface
-- this needs is the ability to change a pending request's preferred time (and, optionally, its
-- requested team member) before confirming it — that capability did not exist anywhere: staff
-- could only accept the customer's original preferred_at as-is or decline outright.
--
-- staff_reschedule_and_confirm_booking_request_v329 updates preferred_at (and staff_id, if a
-- different team member is given) on a still-pending request, in the SAME transaction as the
-- confirm call that follows — so staff_decide_booking_request_v73's own re-read of the row
-- (`select ... for update`) sees the NEW time, not the customer's original one. It deliberately
-- does not duplicate any confirm logic: it writes the two columns, then calls
-- staff_decide_booking_request_v73(p_business, p_request, 'confirm', null) — the exact same
-- wrapper the Confirm button already calls, with the exact same branch resolution (v327) and
-- staff resolution (v328) it already has. A second `for update` on the same row inside the
-- same transaction is a no-op re-lock, not a self-deadlock, so this composes safely with that
-- wrapper's own row lock.

begin;

create or replace function public.staff_reschedule_and_confirm_booking_request_v329(
  p_business uuid,
  p_request uuid,
  p_preferred timestamptz,
  p_staff uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_request public.booking_requests%rowtype;
begin
  -- Defence in depth, matching the existing decline check's shape in
  -- staff_decide_booking_request_v73_v94_base. The real, branch-scoped authorization still
  -- happens inside the staff_decide_booking_request_v73 call below via
  -- app.require_branch_module_v94 — this is not a substitute for it.
  if not app.can_module_write(p_business, 'bookings') then
    raise exception 'booking write access is required' using errcode = '42501';
  end if;

  select * into v_request
    from public.booking_requests
   where id = p_request and business_id = p_business
   for update;
  if not found then
    raise exception 'booking request not found' using errcode = '22023';
  end if;
  if v_request.status not in ('new', 'pending', 'waitlisted') then
    raise exception 'this request is no longer pending' using errcode = '22023';
  end if;

  if p_preferred is null or p_preferred < clock_timestamp() then
    raise exception 'a future date and time is required' using errcode = '22023';
  end if;

  if p_staff is not null and not exists (
    select 1 from public.staff member
     where member.id = p_staff
       and member.business_id = p_business
       and coalesce(member.active, true)
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  update public.booking_requests
     set preferred_at = p_preferred,
         staff_id = coalesce(p_staff, staff_id)
   where id = p_request and business_id = p_business;

  return public.staff_decide_booking_request_v73(p_business, p_request, 'confirm', null);
end;
$$;

revoke all on function public.staff_reschedule_and_confirm_booking_request_v329(
  uuid, uuid, timestamptz, uuid
) from public;
revoke all on function public.staff_reschedule_and_confirm_booking_request_v329(
  uuid, uuid, timestamptz, uuid
) from anon;
grant execute on function public.staff_reschedule_and_confirm_booking_request_v329(
  uuid, uuid, timestamptz, uuid
) to authenticated;

commit;
