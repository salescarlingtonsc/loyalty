-- FRENLY v47 — smart staff scheduling and fail-closed appointment mutations.
-- Forward-only. Local implementation; not applied to a remote database.

begin;

create table app.appointment_booking_operations (
  business_id uuid not null references public.businesses(id) on delete cascade,
  idempotency_key text not null,
  request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
  appointment_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (business_id, idempotency_key),
  foreign key (appointment_id,business_id)
    references public.appointments(id,business_id) on delete cascade
);

alter table app.appointment_booking_operations enable row level security;
revoke all privileges on table app.appointment_booking_operations
  from public, anon, authenticated;

create index appointments_staff_active_window_v47_idx
  on public.appointments (business_id, staff_id, starts_at, ends_at)
  where status = 'booked' and staff_id is not null;

create or replace function app.staff_free_for_appointment_v47(
  p_business uuid,
  p_staff uuid,
  p_branch uuid,
  p_service uuid,
  p_starts timestamptz,
  p_ends timestamptz,
  p_exclude_appointment uuid default null
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
$$;

revoke all privileges on function app.staff_free_for_appointment_v47(
  uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)
  from public, anon, authenticated;

create or replace function public.suggest_appointment_staff_v47(
  p_business uuid,
  p_branch uuid,
  p_service uuid,
  p_starts timestamptz,
  p_duration_minutes integer,
  p_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_ends timestamptz;
  v_timezone text;
  v_day_end timestamptz;
  v_candidate timestamptz;
  v_available jsonb := '[]'::jsonb;
  v_next jsonb := '[]'::jsonb;
  v_staff record;
begin
  if auth.uid() is null
     or not app.can_module_read(p_business, 'appointments')
     or not app.can_see_branch(p_business, p_branch) then
    raise exception 'active appointment access for this branch is required'
      using errcode = '42501';
  end if;
  if p_starts is null or p_duration_minutes not between 15 and 720 then
    raise exception 'appointment duration must be between 15 and 720 minutes'
      using errcode = '22023';
  end if;
  if p_limit not between 1 and 10 then
    raise exception 'suggestion limit must be between 1 and 10'
      using errcode = '22023';
  end if;

  select b.timezone into v_timezone from public.branches b
   where b.id = p_branch and b.business_id = p_business and b.active;
  if not found then
    raise exception 'active branch not found' using errcode = '22023';
  end if;
  if p_service is not null and not exists(
    select 1 from public.services service
     where service.id=p_service and service.business_id=p_business and service.active
       and (
         not exists(select 1 from public.service_branches configured
                     where configured.business_id=p_business and configured.service_id=p_service)
         or exists(select 1 from public.service_branches allowed
                    where allowed.business_id=p_business and allowed.service_id=p_service
                      and allowed.branch_id=p_branch)
       )
  ) then
    raise exception 'service is not bookable at this branch' using errcode = '22023';
  end if;

  v_ends := p_starts + make_interval(mins => p_duration_minutes);
  v_day_end := (((p_starts at time zone v_timezone)::date + 1)::timestamp
                at time zone v_timezone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id', ranked.id,
           'staff_name', ranked.full_name,
           'calendar_color', ranked.calendar_color,
           'recent_appointments', ranked.recent_appointments,
           'hours_configured', ranked.hours_configured
         ) order by ranked.recent_appointments, ranked.last_assigned nulls first,
                    ranked.full_name, ranked.id), '[]'::jsonb)
    into v_available
    from (
      select s.id, s.full_name, s.calendar_color,
             exists(select 1 from public.staff_hours sh
                     where sh.business_id=p_business and sh.staff_id=s.id) as hours_configured,
             (select count(*)::integer from public.appointments a
               where a.business_id=p_business and a.staff_id=s.id
                 and a.status in ('booked','completed')
                 and a.starts_at >= now() - interval '30 days') as recent_appointments,
             (select max(a.created_at) from public.appointments a
               where a.business_id=p_business and a.staff_id=s.id
                 and a.status in ('booked','completed')) as last_assigned
        from public.staff s
        join public.staff_branches sb
          on sb.business_id=s.business_id and sb.staff_id=s.id and sb.branch_id=p_branch
       where s.business_id=p_business and s.active
         and app.staff_free_for_appointment_v47(
               p_business,s.id,p_branch,p_service,p_starts,v_ends,null)
       order by recent_appointments, last_assigned nulls first, s.full_name, s.id
       limit p_limit
    ) ranked;

  v_candidate := p_starts + interval '15 minutes';
  while v_candidate + make_interval(mins => p_duration_minutes) <= v_day_end
        and jsonb_array_length(v_next) < 2 loop
    select s.id, s.full_name, s.calendar_color into v_staff
      from public.staff s
      join public.staff_branches sb
        on sb.business_id=s.business_id and sb.staff_id=s.id and sb.branch_id=p_branch
     where s.business_id=p_business and s.active
       and app.staff_free_for_appointment_v47(
             p_business,s.id,p_branch,p_service,v_candidate,
             v_candidate + make_interval(mins => p_duration_minutes),null)
     order by
       (select count(*) from public.appointments a
         where a.business_id=p_business and a.staff_id=s.id
           and a.status in ('booked','completed')
           and a.starts_at >= now() - interval '30 days'),
       (select max(a.created_at) from public.appointments a
         where a.business_id=p_business and a.staff_id=s.id
           and a.status in ('booked','completed')) nulls first,
       s.full_name, s.id
     limit 1;
    if found then
      v_next := v_next || jsonb_build_array(jsonb_build_object(
        'starts_at', v_candidate,
        'ends_at', v_candidate + make_interval(mins => p_duration_minutes),
        'staff_id', v_staff.id,
        'staff_name', v_staff.full_name,
        'calendar_color', v_staff.calendar_color
      ));
    end if;
    v_candidate := v_candidate + interval '15 minutes';
  end loop;

  return jsonb_build_object(
    'requested_starts_at', p_starts,
    'requested_ends_at', v_ends,
    'available_staff', v_available,
    'recommended_staff_id', v_available #>> '{0,staff_id}',
    'next_best_slots', v_next
  );
end
$$;

revoke all privileges on function public.suggest_appointment_staff_v47(
  uuid,uuid,uuid,timestamptz,integer,integer)
  from public, anon, authenticated;
grant execute on function public.suggest_appointment_staff_v47(
  uuid,uuid,uuid,timestamptz,integer,integer)
  to authenticated;

create or replace function public.book_appointment_smart_v47(
  p_business uuid,
  p_client uuid,
  p_branch uuid,
  p_service uuid,
  p_starts timestamptz,
  p_duration_minutes integer,
  p_requested_staff uuid,
  p_assignment_mode text,
  p_note text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_request_hash text;
  v_existing app.appointment_booking_operations%rowtype;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_staff public.staff%rowtype;
  v_duration integer;
  v_ends timestamptz;
  v_suggestions jsonb;
begin
  if auth.uid() is null
     or not app.can_module_write(p_business, 'appointments')
     or not app.can_see_branch(p_business, p_branch) then
    raise exception 'appointment write access for this branch is required'
      using errcode = '42501';
  end if;
  if p_assignment_mode not in ('manual','round_robin') then
    raise exception 'assignment mode must be manual or round_robin'
      using errcode = '22023';
  end if;
  if p_assignment_mode = 'manual' and p_requested_staff is null then
    raise exception 'manual assignment requires a staff member'
      using errcode = '22023';
  end if;
  if p_starts is null or p_starts < clock_timestamp() - interval '5 minutes' then
    raise exception 'appointment start must be in the future'
      using errcode = '22023';
  end if;
  if p_idempotency_key is null or char_length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required'
      using errcode = '22023';
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    raise exception 'appointment note is too long' using errcode = '22023';
  end if;
  if not exists(select 1 from public.clients c
                 where c.id=p_client and c.business_id=p_business) then
    raise exception 'customer not found' using errcode = '22023';
  end if;
  if not exists(select 1 from public.branches b
                 where b.id=p_branch and b.business_id=p_business and b.active) then
    raise exception 'active branch not found' using errcode = '22023';
  end if;

  if p_service is not null then
    select * into v_service from public.services s
     where s.id=p_service and s.business_id=p_business and s.active;
    if not found then raise exception 'active service not found' using errcode='22023'; end if;
    if exists(select 1 from public.service_branches configured
               where configured.business_id=p_business and configured.service_id=p_service)
       and not exists(select 1 from public.service_branches allowed
                       where allowed.business_id=p_business and allowed.service_id=p_service
                         and allowed.branch_id=p_branch) then
      raise exception 'service is not bookable at this branch' using errcode='22023';
    end if;
    v_duration := v_service.duration_min;
  else
    v_duration := p_duration_minutes;
  end if;
  if v_duration not between 15 and 720 then
    raise exception 'appointment duration must be between 15 and 720 minutes'
      using errcode = '22023';
  end if;
  v_ends := p_starts + make_interval(mins => v_duration);

  v_request_hash := app.v41_request_hash(concat_ws('|',
    p_business::text,p_client::text,p_branch::text,coalesce(p_service::text,''),
    p_starts::text,v_duration::text,coalesce(p_requested_staff::text,''),
    p_assignment_mode,coalesce(p_note,'')));

  perform pg_advisory_xact_lock(hashtextextended(p_business::text, 47));
  select * into v_existing from app.appointment_booking_operations op
   where op.business_id=p_business and op.idempotency_key=btrim(p_idempotency_key);
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key was already used for a different appointment request'
        using errcode = '22023';
    end if;
    select * into v_appointment from public.appointments a
     where a.id=v_existing.appointment_id and a.business_id=p_business;
    return jsonb_build_object('status','booked','replayed',true,
      'appointment_id',v_appointment.id,'staff_id',v_appointment.staff_id,
      'starts_at',v_appointment.starts_at,'ends_at',v_appointment.ends_at);
  end if;

  if p_assignment_mode = 'manual' then
    select * into v_staff from public.staff s
     where s.id=p_requested_staff and s.business_id=p_business and s.active;
    if not found then raise exception 'active staff member not found' using errcode='22023'; end if;
    if not app.staff_free_for_appointment_v47(
      p_business,v_staff.id,p_branch,p_service,p_starts,v_ends,null) then
      v_suggestions := public.suggest_appointment_staff_v47(
        p_business,p_branch,p_service,p_starts,v_duration,5);
      return jsonb_build_object('status','conflict','reason','staff_unavailable',
        'suggestions',v_suggestions);
    end if;
  else
    select s.* into v_staff
      from public.staff s
      join public.staff_branches sb
        on sb.business_id=s.business_id and sb.staff_id=s.id and sb.branch_id=p_branch
     where s.business_id=p_business and s.active
       and app.staff_free_for_appointment_v47(
         p_business,s.id,p_branch,p_service,p_starts,v_ends,null)
     order by
       (select count(*) from public.appointments a
         where a.business_id=p_business and a.staff_id=s.id
           and a.status in ('booked','completed')
           and a.starts_at >= clock_timestamp() - interval '30 days'),
       (select max(a.created_at) from public.appointments a
         where a.business_id=p_business and a.staff_id=s.id
           and a.status in ('booked','completed')) nulls first,
       s.full_name, s.id
     limit 1;
    if not found then
      v_suggestions := public.suggest_appointment_staff_v47(
        p_business,p_branch,p_service,p_starts,v_duration,5);
      return jsonb_build_object('status','conflict','reason','no_staff_available',
        'suggestions',v_suggestions);
    end if;
  end if;

  insert into public.appointments (
    business_id,client_id,branch_id,service_id,staff_id,starts_at,ends_at,
    note,total_cents,source,status
  ) values (
    p_business,p_client,p_branch,p_service,v_staff.id,p_starts,v_ends,
    nullif(btrim(coalesce(p_note,'')),''),coalesce(v_service.price_cents,0),
    'smart_staff','booked'
  ) returning * into v_appointment;

  insert into app.appointment_booking_operations (
    business_id,idempotency_key,request_hash,appointment_id
  ) values (
    p_business,btrim(p_idempotency_key),v_request_hash,v_appointment.id
  );

  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (p_business,auth.uid(),'APPOINTMENT_SMART_BOOK','appointments',v_appointment.id,
    jsonb_build_object('branch_id',p_branch,'staff_id',v_staff.id,
      'assignment_mode',p_assignment_mode,'starts_at',p_starts,'ends_at',v_ends));

  return jsonb_build_object('status','booked','replayed',false,
    'appointment_id',v_appointment.id,'staff_id',v_staff.id,
    'staff_name',v_staff.full_name,'assignment_mode',p_assignment_mode,
    'starts_at',v_appointment.starts_at,'ends_at',v_appointment.ends_at);
end
$$;

revoke all privileges on function public.book_appointment_smart_v47(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.book_appointment_smart_v47(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)
  to authenticated;

create or replace function public.decide_change(p_request uuid,p_approve boolean)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_request public.change_requests%rowtype;
  v_appointment public.appointments%rowtype;
  v_duration integer;
  v_suggestions jsonb;
begin
  select request.* into v_request
    from public.change_requests request where request.id=p_request for update;
  if not found then raise exception 'change request not found' using errcode='22023'; end if;
  select appointment.* into v_appointment
    from public.appointments appointment
   where appointment.id=v_request.appointment_id
     and appointment.business_id=v_request.business_id
   for update;
  if not found then raise exception 'appointment not found' using errcode='22023'; end if;
  if auth.uid() is null
     or not app.can_module_write(v_request.business_id,'appointments')
     or not app.can_see_branch(v_request.business_id,v_appointment.branch_id) then
    raise exception 'appointment write access for this branch is required' using errcode='42501';
  end if;
  if v_request.status<>'pending' then
    raise exception 'change request is already %',v_request.status using errcode='22023';
  end if;
  if not p_approve then
    update public.change_requests set status='declined',decided_at=clock_timestamp()
     where id=p_request;
    return json_build_object('id',p_request,'status','declined','kind',v_request.kind);
  end if;
  if v_appointment.status<>'booked' then
    raise exception 'appointment is no longer booked' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request.business_id::text,47));
  if v_request.kind='reschedule' then
    v_duration:=greatest(15,ceil(extract(epoch from
      (v_appointment.ends_at-v_appointment.starts_at))/60)::integer);
    if v_request.proposed_at is null
       or not app.staff_free_for_appointment_v47(
         v_request.business_id,v_appointment.staff_id,v_appointment.branch_id,
         v_appointment.service_id,v_request.proposed_at,
         v_request.proposed_at+make_interval(mins=>v_duration),v_appointment.id) then
      v_suggestions:=public.suggest_appointment_staff_v47(
        v_request.business_id,v_appointment.branch_id,v_appointment.service_id,
        coalesce(v_request.proposed_at,clock_timestamp()),v_duration,5);
      return json_build_object('id',p_request,'status','conflict','kind',v_request.kind,
        'suggestions',v_suggestions);
    end if;
    update public.appointments
       set starts_at=v_request.proposed_at,
           ends_at=v_request.proposed_at+make_interval(mins=>v_duration)
     where id=v_appointment.id;
  elsif v_request.kind='cancel' then
    update public.appointments set status='cancelled' where id=v_appointment.id;
  else
    raise exception 'unsupported change request type' using errcode='22023';
  end if;
  update public.change_requests set status='approved',decided_at=clock_timestamp()
   where id=p_request;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (v_request.business_id,auth.uid(),'APPOINTMENT_CHANGE_APPROVE','appointments',
    v_appointment.id,jsonb_build_object('request_id',p_request,'kind',v_request.kind,
      'proposed_at',v_request.proposed_at));
  return json_build_object('id',p_request,'status','approved','kind',v_request.kind);
end
$$;

revoke all privileges on function public.decide_change(uuid,boolean)
  from public, anon, authenticated;
grant execute on function public.decide_change(uuid,boolean) to authenticated;

-- Portal conversion chooses the default branch and uses the fair, locked engine.
create or replace function public.convert_booking_request(p_request uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_request public.booking_requests%rowtype;
  v_client uuid;
  v_branch uuid;
  v_start timestamptz;
  v_duration integer;
  v_booking jsonb;
  v_appointment public.appointments%rowtype;
begin
  select request.* into v_request
    from public.booking_requests request where request.id=p_request for update;
  if not found then raise exception 'booking request not found' using errcode='22023'; end if;
  if v_request.appointment_id is not null then
    select * into v_appointment from public.appointments
     where id=v_request.appointment_id and business_id=v_request.business_id;
    return row_to_json(v_appointment);
  end if;
  v_branch:=app.default_branch(v_request.business_id);
  if v_branch is null then raise exception 'an active default branch is required' using errcode='22023'; end if;
  if not app.can_module_write(v_request.business_id,'appointments')
     or not app.can_see_branch(v_request.business_id,v_branch) then
    raise exception 'appointment write access for the default branch is required' using errcode='42501';
  end if;
  v_client:=app.upsert_portal_client(
    v_request.business_id,v_request.name,v_request.phone,v_request.email);
  perform app.apply_booking_consent(
    v_request.business_id,v_client,v_request.marketing_consent);
  v_start:=coalesce(v_request.preferred_at,clock_timestamp()+interval '1 day');
  select greatest(service.duration_min,15) into v_duration
    from public.services service
   where service.id=v_request.service_id and service.business_id=v_request.business_id;
  v_duration:=coalesce(v_duration,60);
  v_booking:=public.book_appointment_smart_v47(
    v_request.business_id,v_client,v_branch,v_request.service_id,v_start,v_duration,
    null,'round_robin',v_request.notes,'booking-request:'||p_request::text);
  if v_booking->>'status'='conflict' then return v_booking::json; end if;
  select * into v_appointment from public.appointments
   where id=(v_booking->>'appointment_id')::uuid and business_id=v_request.business_id;
  update public.appointments
     set party_size=v_request.party_size,source='portal',table_type_id=v_request.table_type_id
   where id=v_appointment.id returning * into v_appointment;
  update public.booking_requests
     set status='confirmed',appointment_id=v_appointment.id,expires_at=null
   where id=p_request;
  return row_to_json(v_appointment);
end
$$;

revoke all privileges on function public.convert_booking_request(uuid)
  from public, anon, authenticated;
grant execute on function public.convert_booking_request(uuid) to authenticated;

-- Retire the legacy phone-sale overload. Quick earn must provide an explicit
-- authorized branch and a received tender, then delegate to v20's atomic
-- sale+payment operation instead of creating a financially orphaned sale.
revoke all privileges on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text) from public, anon, authenticated;

create or replace function public.record_sale_by_phone(
  p_business uuid,p_phone text,p_amount_cents integer,
  p_kind text default 'quick_sale',p_note text default null,
  p_staff uuid default null,p_idem text default null,
  p_branch uuid default null,p_method text default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_norm text;
  v_actor_staff uuid;
  v_client public.clients%rowtype;
  v_financial jsonb;
  v_sale_id uuid;
  v_payment_id uuid;
  v_points_earned integer;
  v_points_after integer;
  v_note text;
begin
  if not app.has_perm(p_business,'create_sales')
     or not app.can_module_read(p_business,'clients') then
    raise exception 'clients read and create-sales authorization is required' using errcode='42501';
  end if;
  select staff.id into v_actor_staff from public.staff staff
   where staff.business_id=p_business and staff.user_id=auth.uid() and staff.active limit 1;
  if not found then raise exception 'an active staff identity is required' using errcode='42501'; end if;
  if p_staff is not null and p_staff is distinct from v_actor_staff then
    raise exception 'sale staff attribution must match the authenticated staff identity'
      using errcode='42501';
  end if;
  if p_idem is null or char_length(btrim(p_idem)) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode='22023';
  end if;
  if p_amount_cents is null or p_amount_cents<=0 then
    raise exception 'Enter the amount paid.' using errcode='22023';
  end if;
  if p_kind is distinct from 'quick_sale' then
    raise exception 'Quick earn only accepts quick-sale purchases' using errcode='22023';
  end if;
  if p_branch is null then
    raise exception 'Choose the branch where payment was received' using errcode='22023';
  end if;
  if lower(coalesce(btrim(p_method),'')) not in ('cash','card','paynow','other') then
    raise exception 'Choose Cash, Card, PayNow or Other' using errcode='22023';
  end if;
  if p_note is not null and char_length(p_note)>1000 then
    raise exception 'sale note is too long' using errcode='22023';
  end if;
  v_norm:=app.norm_phone(p_phone);
  if v_norm is null then raise exception 'Enter a valid 8-digit mobile number.' using errcode='22023'; end if;
  select * into v_client from public.clients
   where business_id=p_business and phone_norm=v_norm;
  if not found then raise exception 'No customer with that number. Add them first.' using errcode='22023'; end if;
  v_note:=coalesce(p_note,'till: '||v_norm);
  v_financial:=public.record_quick_sale(
    p_business=>p_business,p_amount_cents=>p_amount_cents,
    p_method=>lower(btrim(p_method)),p_client=>v_client.id,p_staff=>v_actor_staff,
    p_branch=>p_branch,p_note=>v_note,p_idempotency_key=>btrim(p_idem),p_paid=>true
  )::jsonb;
  v_sale_id:=nullif(v_financial #>> '{sale,id}','')::uuid;
  v_payment_id:=nullif(v_financial->>'payment_id','')::uuid;
  if v_sale_id is null or v_payment_id is null then
    raise exception 'Quick earn did not produce exact sale and payment proof' using errcode='XX001';
  end if;
  select coalesce(sum(points),0) into v_points_earned from public.points_ledger
   where business_id=p_business and client_id=v_client.id and sale_id=v_sale_id;
  select coalesce(sum(points),0) into v_points_after from public.points_ledger
   where business_id=p_business and client_id=v_client.id;
  return json_build_object(
    'status',case when coalesce((v_financial->>'replayed')::boolean,false)
                  then 'duplicate_ignored' else 'ok' end,
    'sale_id',v_sale_id,'payment_id',v_payment_id,'client_id',v_client.id,
    'full_name',v_client.full_name,'amount_cents',p_amount_cents,'kind','quick_sale',
    'branch_id',p_branch,'payment_method',lower(btrim(p_method)),
    'points_earned',case when coalesce((v_financial->>'replayed')::boolean,false)
                         then 0 else v_points_earned end,
    'points',v_points_after
  );
end
$$;

revoke all privileges on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text,uuid,text) from public, anon, authenticated;
grant execute on function public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text,uuid,text) to authenticated;

-- Preserve completion behavior while carrying appointment branch into the sale.
create or replace function app.on_appointment_completed()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_amount integer;
  v_component record;
  v_batch record;
  v_need integer;
  v_take integer;
  v_staff uuid;
begin
  if new.status='completed' and old.status is distinct from 'completed' then
    v_amount:=coalesce(nullif(new.total_cents,0),
      (select service.price_cents from public.services service where service.id=new.service_id),0);
    if new.staff_id is not null then
      select staff.id into v_staff from public.staff staff
       where staff.id=new.staff_id and staff.business_id=new.business_id;
      if not found then
        raise exception 'appointment staff does not belong to this business' using errcode='23503';
      end if;
    end if;
    insert into public.sales(
      business_id,client_id,kind,amount_cents,appointment_id,staff_id,branch_id,note
    ) values (
      new.business_id,new.client_id,'service',v_amount,new.id,v_staff,new.branch_id,
      'appointment completed'
    ) on conflict do nothing;
    if new.service_id is not null then
      for v_component in select product_id,qty from public.service_products
        where service_id=new.service_id loop
        v_need:=v_component.qty;
        for v_batch in select id,qty from public.stock_batches
          where product_id=v_component.product_id and qty>0
          order by expires_on nulls last,received_on,id loop
          exit when v_need<=0;
          v_take:=least(v_batch.qty,v_need);
          update public.stock_batches set qty=qty-v_take where id=v_batch.id;
          v_need:=v_need-v_take;
        end loop;
      end loop;
    end if;
  end if;
  return new;
end
$$;

revoke all privileges on function app.on_appointment_completed()
  from public, anon, authenticated;

create or replace function public.set_appointment_status_v47(
  p_business uuid,
  p_appointment uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_appointment public.appointments%rowtype;
begin
  if auth.uid() is null or not app.can_module_write(p_business,'appointments') then
    raise exception 'appointment write access is required' using errcode='42501';
  end if;
  if p_status not in ('completed','cancelled','no_show') then
    raise exception 'unsupported appointment status transition' using errcode='22023';
  end if;
  if p_status='completed' and not app.has_perm(p_business,'create_sales') then
    raise exception 'create-sales authorization is required to complete an appointment'
      using errcode='42501';
  end if;
  select * into v_appointment from public.appointments a
   where a.id=p_appointment and a.business_id=p_business for update;
  if not found or not app.can_see_branch(p_business,v_appointment.branch_id) then
    raise exception 'appointment not found for this branch scope' using errcode='42501';
  end if;
  if p_status in ('completed','no_show') and v_appointment.starts_at>clock_timestamp() then
    raise exception 'a future appointment cannot be completed or marked no-show'
      using errcode='22023';
  end if;
  if v_appointment.status=p_status then
    return jsonb_build_object('status',p_status,'replayed',true,
      'appointment_id',p_appointment);
  end if;
  if v_appointment.status<>'booked' then
    raise exception 'appointment is already % and cannot move to %',v_appointment.status,p_status
      using errcode='22023';
  end if;
  update public.appointments set status=p_status where id=p_appointment;
  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (p_business,auth.uid(),'APPOINTMENT_STATUS','appointments',p_appointment,
    jsonb_build_object('from','booked','to',p_status));
  return jsonb_build_object('status',p_status,'replayed',false,
    'appointment_id',p_appointment);
end
$$;

revoke all privileges on function public.set_appointment_status_v47(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.set_appointment_status_v47(uuid,uuid,text)
  to authenticated;

drop policy if exists appointments_all on public.appointments;
drop policy if exists appointments_read on public.appointments;
drop policy if exists appointments_ins on public.appointments;
drop policy if exists appointments_upd on public.appointments;
drop policy if exists appointments_del on public.appointments;
drop policy if exists appointments_v47_read on public.appointments;
create policy appointments_v47_read on public.appointments
  for select to authenticated
  using (
    app.can_module_read(business_id,'appointments')
    and app.can_see_branch(business_id,branch_id)
  );

revoke insert, update, delete, truncate on table public.appointments
  from public, anon, authenticated;
grant select on table public.appointments to authenticated;

notify pgrst, 'reload schema';

commit;
