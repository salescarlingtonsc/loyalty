-- v328 — honour the customer's staff choice on manual (non-auto-confirm) booking confirmation
--
-- Bug (found while reading staff_decide_booking_request_v73_v94_base alongside v183 and v327):
-- v183 (20260806_nestly_v183_customer_staff_choice_and_live_availability.sql) stores the
-- customer's chosen team member on booking_requests.staff_id. The auto-confirm path
-- (internal_public_booking_submit, same file) already honours it — it UPDATEs the freshly
-- created appointment's staff_id right after booking, guarded by "staff_id is null" so it
-- never clobbers an assignment book_appointment_smart_v47 already made.
--
-- The manual-review path never got the same treatment. staff_decide_booking_request_v73_v94_base
-- (originally staff_decide_booking_request_v73 in 20260726_frenly_v73_booking_lifecycle.sql,
-- renamed by v94) calls book_appointment_smart_v47 with a hardcoded `null, 'round_robin'` for
-- the staff arguments, no matter what booking_requests.staff_id holds. So for a business with
-- booking_staff_choice = true AND booking_auto_confirm = false, a customer's staff pick is
-- captured on the request row and then silently thrown away the moment staff manually confirm
-- it — the appointment lands on whoever round-robin picks, not the person the customer asked
-- for.
--
-- Fix mirrors the exact "customer choice wins over default, falls back if it no longer holds"
-- pattern this same function already uses for v_request.branch_id (see v327,
-- db/migrations/20260815_nestly_v327_customer_branch_choice.sql, currently on its own
-- unmerged branch — not yet part of this history, but the reference for style and the
-- revoke/grant conventions below): if the request's staff_id still points at an active staff
-- member of this business, pass it through as p_requested_staff with assignment_mode='manual';
-- otherwise fall back to null/'round_robin' exactly as before. p_branch stays untouched — this
-- migration is staff-only.
--
-- Only the function body changes; signature, grants, and every branch-handling line are
-- unchanged copies of the current live body (20260728_nestly_v94_platform_control_intelligence.sql).

begin;

create or replace function public.staff_decide_booking_request_v73_v94_base(
  p_business uuid,
  p_request uuid,
  p_decision text,
  p_branch uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_request public.booking_requests%rowtype;
  v_waitlist public.waitlist%rowtype;
  v_appointment public.appointments%rowtype;
  v_client uuid;
  v_branch uuid;
  v_staff uuid;
  v_duration integer;
  v_available integer;
  v_booking jsonb;
begin
  if p_business is null or p_request is null or p_decision is null
     or p_decision not in ('confirm', 'decline') then
    raise exception 'invalid booking decision request' using errcode = '22023';
  end if;
  if v_actor is null then
    raise exception 'authenticated staff session is required' using errcode = '42501';
  end if;

  -- This is the natural idempotency lock. Every later lock follows it.
  select request.* into v_request
    from public.booking_requests request
   where request.id = p_request
     and request.business_id = p_business
   for update;
  if not found then
    raise exception 'booking request not found' using errcode = '22023';
  end if;

  select waitlist_row.* into v_waitlist
    from public.waitlist waitlist_row
   where waitlist_row.booking_request_id = p_request
     and waitlist_row.business_id = p_business
   for update;

  if p_decision = 'decline' then
    if not app.can_module_write(p_business, 'bookings') then
      raise exception 'booking write access is required' using errcode = '42501';
    end if;
    if v_request.status = 'declined' then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'replayed', true
      );
    end if;
    if v_request.status in ('confirmed', 'expired', 'cancelled') then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'terminal_conflict', false
      );
    end if;
    if v_request.status not in ('new', 'pending', 'waitlisted') then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'state_conflict', false
      );
    end if;
    if (v_request.status = 'waitlisted' and v_waitlist.id is null)
       or (v_waitlist.id is not null
           and v_waitlist.status not in ('waiting', 'contacted')) then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'waitlist_conflict', false
      );
    end if;

    update public.booking_requests
       set status = 'declined',
           expires_at = null
     where id = p_request
       and business_id = p_business;
    if v_waitlist.id is not null then
      update public.waitlist
         set status = 'removed'
       where id = v_waitlist.id
         and business_id = p_business;
    end if;
    insert into public.audit_log(
      business_id, actor, action, entity, entity_id, detail
    ) values (
      p_business, v_actor, 'BOOKING_REQUEST_DECISION_V73',
      'booking_requests', p_request,
      jsonb_build_object(
        'decision', 'decline',
        'from_status', v_request.status,
        'to_status', 'declined',
        'waitlist_id', v_waitlist.id
      )
    );
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'applied', false
    );
  end if;

  -- Confirm always requires the appointments write boundary as well.
  if not app.can_module_write(p_business, 'appointments') then
    raise exception 'appointment write access is required' using errcode = '42501';
  end if;

  if v_request.status = 'confirmed' then
    select appointment.* into v_appointment
      from public.appointments appointment
     where appointment.id = v_request.appointment_id
       and appointment.business_id = p_business;
    if not found or v_appointment.branch_id is null
       or not app.can_see_branch(p_business, v_appointment.branch_id) then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'terminal_conflict', false
      );
    end if;
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'replayed', true
    );
  end if;
  if v_request.status in ('declined', 'expired', 'cancelled') then
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'terminal_conflict', false
    );
  end if;
  if v_request.status not in ('new', 'pending', 'waitlisted') then
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'state_conflict', false
    );
  end if;
  if (v_request.status = 'waitlisted' and v_waitlist.id is null)
     or (v_waitlist.id is not null
         and v_waitlist.status not in ('waiting', 'contacted')) then
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'waitlist_conflict', false
    );
  end if;

  if p_branch is not null then
    select branch.id into v_branch
      from public.branches branch
     where branch.id = p_branch
       and branch.business_id = p_business
       and branch.active;
  else
    select branch.id into v_branch
      from public.branches branch
     where branch.business_id = p_business
       and branch.active
     order by branch.is_default desc, branch.created_at, branch.id
     limit 1;
  end if;
  if v_branch is null then
    raise exception 'an active booking branch is required' using errcode = '22023';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'appointment write access for this branch is required'
      using errcode = '42501';
  end if;

  -- v328: the CUSTOMER's staff choice (v183, booking_requests.staff_id) wins over round-robin
  -- when they made one. If that staff member is gone or was deactivated since the request came
  -- in, fall through to round-robin exactly as before, rather than failing the confirmation.
  if v_request.staff_id is not null then
    select member.id into v_staff
      from public.staff member
     where member.id = v_request.staff_id
       and member.business_id = p_business
       and coalesce(member.active, true);
  end if;

  -- Waitlisted table requests do not hold capacity. Serialize against the table
  -- type and re-read actual current availability before creating an appointment.
  if v_request.table_type_id is not null
     and (
       v_request.status = 'waitlisted'
       or (
         v_request.status = 'pending'
         and v_request.expires_at is not null
         and v_request.expires_at <= clock_timestamp()
       )
     ) then
    perform 1
      from public.booking_tables table_type
     where table_type.id = v_request.table_type_id
       and table_type.business_id = p_business
       and table_type.active
     for update;
    if not found then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'capacity_conflict', false
      );
    end if;
    select greatest(
      table_type.quantity
      - (
        select count(*)::integer
          from public.booking_requests held_request
         where held_request.table_type_id = v_request.table_type_id
           and held_request.status in ('new', 'pending')
           and held_request.id <> p_request
           and (
             held_request.expires_at is null
             or held_request.expires_at > clock_timestamp()
           )
      )
      - (
        select count(*)::integer
          from public.appointments held_appointment
         where held_appointment.table_type_id = v_request.table_type_id
           and held_appointment.status = 'booked'
      ),
      0
    ) into v_available
      from public.booking_tables table_type
     where table_type.id = v_request.table_type_id
       and table_type.business_id = p_business;
    if coalesce(v_available, 0) <= 0 then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'capacity_conflict', false
      );
    end if;
  end if;

  -- Keep guest client creation/consent inside a subtransaction. If scheduling
  -- conflicts, the exception handler rolls every tentative side effect back.
  begin
    if v_request.customer_client_id is not null then
      select client.id into v_client
        from public.clients client
       where client.id = v_request.customer_client_id
         and client.business_id = p_business;
      if not found then
        raise exception 'bound booking client is unavailable' using errcode = '23503';
      end if;
    else
      v_client := app.upsert_portal_client(
        p_business, v_request.name, v_request.phone, v_request.email
      );
      perform app.apply_booking_consent(
        p_business, v_client, v_request.marketing_consent
      );
    end if;

    select greatest(service.duration_min, 15) into v_duration
      from public.services service
     where service.id = v_request.service_id
       and service.business_id = p_business;
    v_duration := coalesce(v_duration, 60);

    v_booking := public.book_appointment_smart_v47(
      p_business, v_client, v_branch, v_request.service_id,
      coalesce(v_request.preferred_at, clock_timestamp() + interval '1 day'),
      v_duration, v_staff,
      case when v_staff is not null then 'manual' else 'round_robin' end,
      v_request.notes,
      'booking-request:' || p_request::text
    );
    if v_booking->>'status' = 'conflict' then
      raise exception 'v73 scheduling conflict' using errcode = 'P0731';
    end if;

    select appointment.* into v_appointment
      from public.appointments appointment
     where appointment.id = (v_booking->>'appointment_id')::uuid
       and appointment.business_id = p_business;
    if not found then
      raise exception 'scheduler returned no appointment' using errcode = 'P0001';
    end if;

    update public.appointments
       set party_size = v_request.party_size,
           source = 'portal',
           table_type_id = v_request.table_type_id
     where id = v_appointment.id
       and business_id = p_business
    returning * into v_appointment;

    update public.booking_requests
       set status = 'confirmed',
           appointment_id = v_appointment.id,
           expires_at = null
     where id = p_request
       and business_id = p_business;
    if v_waitlist.id is not null then
      update public.waitlist
         set status = 'booked'
       where id = v_waitlist.id
         and business_id = p_business;
    end if;

    insert into public.audit_log(
      business_id, actor, action, entity, entity_id, detail
    ) values (
      p_business, v_actor, 'BOOKING_REQUEST_DECISION_V73',
      'booking_requests', p_request,
      jsonb_build_object(
        'decision', 'confirm',
        'from_status', v_request.status,
        'to_status', 'confirmed',
        'appointment_id', v_appointment.id,
        'branch_id', v_branch,
        'staff_id', v_staff,
        'waitlist_id', v_waitlist.id
      )
    );
  exception
    when sqlstate 'P0731' or exclusion_violation then
      return app.booking_decision_result_v73(
        p_business, p_request, p_decision, 'scheduling_conflict', false
      );
  end;

  return app.booking_decision_result_v73(
    p_business, p_request, p_decision, 'applied', false
  );
end
$$;

revoke all on function public.staff_decide_booking_request_v73_v94_base(
  uuid,uuid,text,uuid
) from public,anon,authenticated,service_role;

commit;
