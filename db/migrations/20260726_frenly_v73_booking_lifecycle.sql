-- FRENLY v73 - ATOMIC STAFF BOOKING REQUEST LIFECYCLE
--
-- Local forward-only review candidate. This increment gives the staff Bookings
-- surface one tenant-scoped confirm/decline transition. It does not add a new
-- browser identity, direct table writes, or seat-without-appointment semantics.

begin;

-- A pending/new request whose finite hold has elapsed is no longer live. Keep
-- availability discovery and the locked confirmation recheck on the same rule.
create or replace view public.v_table_availability
with (security_invoker = true) as
select
  table_type.business_id,
  table_type.id as table_type_id,
  table_type.name,
  table_type.pax,
  table_type.quantity,
  table_type.sort,
  holds.held,
  greatest(table_type.quantity - holds.held, 0) as available
from public.booking_tables table_type
cross join lateral (
  select (
      (
        select count(*)
          from public.booking_requests held_request
         where held_request.table_type_id = table_type.id
           and held_request.status in ('new', 'pending')
           and (
             held_request.expires_at is null
             or held_request.expires_at > clock_timestamp()
           )
      )
      + (
        select count(*)
          from public.appointments held_appointment
         where held_appointment.table_type_id = table_type.id
           and held_appointment.status = 'booked'
      )
    )::integer as held
) holds
where table_type.active;

-- The composite FK and one-request/one-linked-waitlist invariant cannot be
-- installed safely if legacy rows disagree. Fail before changing the catalog.
do $v73_waitlist_preflight$
begin
  if exists (
    select 1
      from public.waitlist waitlist_row
      join public.booking_requests request
        on request.id = waitlist_row.booking_request_id
     where waitlist_row.booking_request_id is not null
       and waitlist_row.business_id <> request.business_id
  ) then
    raise exception 'v73 preflight: cross-tenant linked waitlist row exists';
  end if;
  if exists (
    select 1
      from public.waitlist waitlist_row
     where waitlist_row.booking_request_id is not null
     group by waitlist_row.booking_request_id
    having count(*) > 1
  ) then
    raise exception 'v73 preflight: duplicate linked waitlist rows exist';
  end if;
end
$v73_waitlist_preflight$;

alter table public.waitlist
  drop constraint if exists waitlist_booking_request_id_fkey;

alter table public.waitlist
  add constraint waitlist_booking_request_business_fk_v73
  foreign key (booking_request_id, business_id)
  references public.booking_requests(id, business_id)
  on delete set null (booking_request_id);

create unique index waitlist_one_link_per_booking_request_v73_uk
  on public.waitlist(booking_request_id)
  where booking_request_id is not null;

-- Private safe response builder. It deliberately projects no submitted contact,
-- client identity, free-form note, staff identity, or management capability.
create or replace function app.booking_decision_result_v73(
  p_business uuid,
  p_request uuid,
  p_decision text,
  p_outcome text,
  p_replayed boolean
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'request_id', request.id,
    'requested_decision', p_decision,
    'outcome', p_outcome,
    'actual_status', request.status,
    'replayed', p_replayed
  ) || jsonb_strip_nulls(jsonb_build_object(
    'appointment_id', appointment.id,
    'branch_id', appointment.branch_id,
    'starts_at', appointment.starts_at,
    'ends_at', appointment.ends_at,
    'waitlist_id', waitlist_row.id,
    'waitlist_status', waitlist_row.status
  ))
    from public.booking_requests request
    left join public.appointments appointment
      on appointment.id = request.appointment_id
     and appointment.business_id = request.business_id
    left join public.waitlist waitlist_row
      on waitlist_row.booking_request_id = request.id
     and waitlist_row.business_id = request.business_id
   where request.id = p_request
     and request.business_id = p_business
$$;

create or replace function public.staff_decide_booking_request_v73(
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
      v_duration, null, 'round_robin', v_request.notes,
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

-- Exact legacy signature/ACL retained. The wrapper cannot recurse: all lifecycle
-- work is delegated to the distinct v73 RPC, then successful confirms preserve
-- the legacy appointment-row response expected by the current staff UI.
create or replace function public.convert_booking_request(p_request uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_result jsonb;
  v_legacy json;
begin
  select request.business_id into v_business
    from public.booking_requests request
   where request.id = p_request;
  if not found then
    raise exception 'booking request not found' using errcode = '22023';
  end if;

  v_result := public.staff_decide_booking_request_v73(
    v_business, p_request, 'confirm', null
  );
  if v_result->>'outcome' in ('applied', 'replayed') then
    select row_to_json(appointment) into v_legacy
      from public.appointments appointment
     where appointment.id = (v_result->>'appointment_id')::uuid
       and appointment.business_id = v_business;
    return v_legacy;
  end if;
  return jsonb_build_object(
    'status', 'conflict',
    'reason', v_result->>'outcome',
    'request_id', p_request
  )::json;
end
$$;

revoke all on function app.booking_decision_result_v73(
  uuid,uuid,text,text,boolean
) from public, anon, authenticated;
revoke all on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) from public, anon, authenticated;
grant execute on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) to authenticated;
revoke all on function public.convert_booking_request(uuid)
  from public, anon, authenticated;
grant execute on function public.convert_booking_request(uuid)
  to authenticated;

do $v73_catalog_gate$
begin
  if has_function_privilege(
       'anon',
       'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)',
       'execute'
     ) or not has_function_privilege(
       'authenticated',
       'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)',
       'execute'
     ) or has_function_privilege(
       'anon', 'public.convert_booking_request(uuid)', 'execute'
     ) or not has_function_privilege(
       'authenticated', 'public.convert_booking_request(uuid)', 'execute'
     ) then
    raise exception 'v73 booking lifecycle ACL drifted';
  end if;
  if not exists (
    select 1
      from pg_constraint constraint_row
     where constraint_row.conname = 'waitlist_booking_request_business_fk_v73'
       and constraint_row.conrelid = 'public.waitlist'::regclass
       and constraint_row.contype = 'f'
  ) or not exists (
    select 1
      from pg_indexes index_row
     where index_row.schemaname = 'public'
       and index_row.tablename = 'waitlist'
       and index_row.indexname = 'waitlist_one_link_per_booking_request_v73_uk'
  ) then
    raise exception 'v73 linked waitlist invariant is missing';
  end if;
end
$v73_catalog_gate$;

commit;
