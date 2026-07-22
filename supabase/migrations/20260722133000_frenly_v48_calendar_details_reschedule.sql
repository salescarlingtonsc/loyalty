-- FRENLY v48 — appointment details, hardened rescheduling and customer-safe confirmation.
-- Forward-only local implementation. No external delivery provider is invoked here.

begin;

-- C46 intentionally uses finite customer-safe copy. Extend only the reviewed booking
-- confirmation vocabulary; no client PII, appointment note or commercial detail enters it.
alter table public.customer_in_app_inbox_events
  drop constraint customer_in_app_inbox_events_source_kind_check,
  add constraint customer_in_app_inbox_events_source_kind_check check (source_kind in (
    'c44_actionable_wallet', 'c45_birthday_benefit', 'v33_booking_action',
    'v48_appointment_reschedule'
  )),
  drop constraint customer_in_app_inbox_events_title_check,
  add constraint customer_in_app_inbox_events_title_check check (title in (
    'Points expire soon', 'Stamps expire soon', 'A reward is ready', 'One visit to go',
    'Birthday benefit ready', 'Appointment request received', 'Appointment time changed'
  )),
  drop constraint customer_in_app_inbox_events_body_check,
  add constraint customer_in_app_inbox_events_body_check check (body in (
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to view the available reward.',
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to view your birthday benefit.',
    'Open this business wallet to review your appointment request.',
    'Open this business wallet to review your updated appointment.'
  ));

create or replace function app.c46_inbox_source_available(
  p_source_kind text,
  p_actionable_wallet_enabled boolean
)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select $1 in ('v33_booking_action','v48_appointment_reschedule')
      or (coalesce($2, false) and $1 in ('c44_actionable_wallet','c45_birthday_benefit'))
$$;

create table app.appointment_reschedule_operations (
  business_id uuid not null references public.businesses(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  appointment_id uuid not null,
  actor uuid not null references auth.users(id) on delete restrict,
  old_starts_at timestamptz not null,
  old_ends_at timestamptz not null,
  old_staff_id uuid,
  requested_starts_at timestamptz not null,
  requested_ends_at timestamptz not null,
  requested_staff_id uuid not null,
  outcome text not null check (outcome in ('rescheduled','conflict')),
  notification_state text not null check (
    notification_state in ('in_app_created','suppressed','unavailable','not_applicable')
  ),
  response jsonb not null check (jsonb_typeof(response)='object'),
  created_at timestamptz not null default clock_timestamp(),
  primary key (business_id,idempotency_key),
  foreign key (appointment_id,business_id)
    references public.appointments(id,business_id) on delete restrict
);

alter table app.appointment_reschedule_operations enable row level security;
revoke all privileges on table app.appointment_reschedule_operations
  from public, anon, authenticated;

create trigger appointment_reschedule_operations_immutable_guard
  before update or delete on app.appointment_reschedule_operations
  for each row execute function app.c46_append_only_guard();

create or replace function app.suggest_appointment_reschedule_v48(
  p_business uuid,
  p_appointment uuid,
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
  v_ends timestamptz := p_starts + make_interval(mins=>p_duration_minutes);
  v_timezone text;
  v_day_end timestamptz;
  v_candidate timestamptz;
  v_available jsonb := '[]'::jsonb;
  v_next jsonb := '[]'::jsonb;
  v_staff record;
begin
  select branch.timezone into v_timezone from public.branches branch
   where branch.id=p_branch and branch.business_id=p_business and branch.active;
  if not found then raise exception 'active branch not found' using errcode='22023'; end if;
  v_day_end:=(((p_starts at time zone v_timezone)::date+1)::timestamp at time zone v_timezone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id',ranked.id,'staff_name',ranked.full_name,
           'calendar_color',ranked.calendar_color,'recent_appointments',ranked.recent_appointments
         ) order by ranked.recent_appointments,ranked.last_assigned nulls first,
                    ranked.full_name,ranked.id),'[]'::jsonb)
    into v_available
    from (
      select staff.id,staff.full_name,staff.calendar_color,
             (select count(*)::integer from public.appointments recent
               where recent.business_id=p_business and recent.staff_id=staff.id
                 and recent.status in ('booked','completed')
                 and recent.starts_at>=clock_timestamp()-interval '30 days') recent_appointments,
             (select max(recent.created_at) from public.appointments recent
               where recent.business_id=p_business and recent.staff_id=staff.id
                 and recent.status in ('booked','completed')) last_assigned
        from public.staff staff
        join public.staff_branches staff_branch
          on staff_branch.business_id=staff.business_id and staff_branch.staff_id=staff.id
         and staff_branch.branch_id=p_branch
       where staff.business_id=p_business and staff.active
         and app.staff_free_for_appointment_v47(
           p_business,staff.id,p_branch,p_service,p_starts,v_ends,p_appointment)
       order by recent_appointments,last_assigned nulls first,staff.full_name,staff.id
       limit p_limit
    ) ranked;

  v_candidate:=p_starts+interval '15 minutes';
  while v_candidate+make_interval(mins=>p_duration_minutes)<=v_day_end
        and jsonb_array_length(v_next)<2 loop
    select staff.id,staff.full_name,staff.calendar_color into v_staff
      from public.staff staff
      join public.staff_branches staff_branch
        on staff_branch.business_id=staff.business_id and staff_branch.staff_id=staff.id
       and staff_branch.branch_id=p_branch
     where staff.business_id=p_business and staff.active
       and app.staff_free_for_appointment_v47(
         p_business,staff.id,p_branch,p_service,v_candidate,
         v_candidate+make_interval(mins=>p_duration_minutes),p_appointment)
     order by
       (select count(*) from public.appointments recent
         where recent.business_id=p_business and recent.staff_id=staff.id
           and recent.status in ('booked','completed')
           and recent.starts_at>=clock_timestamp()-interval '30 days'),
       (select max(recent.created_at) from public.appointments recent
         where recent.business_id=p_business and recent.staff_id=staff.id
           and recent.status in ('booked','completed')) nulls first,
       staff.full_name,staff.id
     limit 1;
    if found then
      v_next:=v_next||jsonb_build_array(jsonb_build_object(
        'starts_at',v_candidate,
        'ends_at',v_candidate+make_interval(mins=>p_duration_minutes),
        'staff_id',v_staff.id,'staff_name',v_staff.full_name,
        'calendar_color',v_staff.calendar_color
      ));
    end if;
    v_candidate:=v_candidate+interval '15 minutes';
  end loop;
  return jsonb_build_object(
    'requested_starts_at',p_starts,'requested_ends_at',v_ends,
    'available_staff',v_available,'recommended_staff_id',v_available#>>'{0,staff_id}',
    'next_best_slots',v_next
  );
end
$$;

revoke all privileges on function app.suggest_appointment_reschedule_v48(
  uuid,uuid,uuid,uuid,timestamptz,integer,integer)
  from public, anon, authenticated;

create or replace function public.reschedule_appointment_v48(
  p_business uuid,
  p_appointment uuid,
  p_starts timestamptz,
  p_duration_minutes integer,
  p_staff uuid,
  p_note text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_appointment public.appointments%rowtype;
  v_existing app.appointment_reschedule_operations%rowtype;
  v_request_hash text;
  v_ends timestamptz;
  v_note text:=nullif(btrim(coalesce(p_note,'')),'');
  v_suggestions jsonb;
  v_response jsonb;
  v_identity public.customer_identities%rowtype;
  v_link public.customer_links%rowtype;
  v_notification_state text:='unavailable';
  v_source_fingerprint text;
  v_dedupe_key text;
begin
  if v_actor is null or not app.can_module_write(p_business,'appointments') then
    raise exception 'appointment write access is required' using errcode='42501';
  end if;
  if p_appointment is null or p_staff is null or p_starts is null
     or p_idempotency_key is null or p_duration_minutes not between 15 and 720 then
    raise exception 'appointment, future time, duration, staff and idempotency key are required'
      using errcode='22023';
  end if;
  if p_starts<=clock_timestamp() then
    raise exception 'appointment start must be in the future' using errcode='22023';
  end if;
  if p_note is not null and (char_length(p_note)>1000 or p_note is distinct from btrim(p_note)) then
    raise exception 'appointment note must be trimmed and at most 1000 characters'
      using errcode='22023';
  end if;
  v_ends:=p_starts+make_interval(mins=>p_duration_minutes);
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object(
    'business_id',p_business,'appointment_id',p_appointment,'starts_at',p_starts,
    'duration_minutes',p_duration_minutes,'staff_id',p_staff,'note',v_note
  )::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v48:appointment-reschedule:'||p_business::text||':'||p_idempotency_key::text,0));
  select operation.* into v_existing from app.appointment_reschedule_operations operation
   where operation.business_id=p_business and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for a different appointment change'
        using errcode='22023';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v48:appointment:'||p_business::text||':'||p_appointment::text,0));
  select appointment.* into v_appointment from public.appointments appointment
   where appointment.id=p_appointment and appointment.business_id=p_business for update;
  if not found or not app.can_see_branch(p_business,v_appointment.branch_id) then
    raise exception 'appointment not found for this branch scope' using errcode='42501';
  end if;
  if v_appointment.status<>'booked' or v_appointment.starts_at<=clock_timestamp() then
    raise exception 'only a future booked appointment can be changed' using errcode='22023';
  end if;
  if not exists(select 1 from public.branches branch
                 where branch.id=v_appointment.branch_id
                   and branch.business_id=p_business and branch.active) then
    raise exception 'appointment branch is not active' using errcode='22023';
  end if;
  if v_appointment.service_id is not null and not exists(
    select 1 from public.services service
     where service.id=v_appointment.service_id and service.business_id=p_business and service.active
       and (
         not exists(select 1 from public.service_branches configured
                     where configured.business_id=p_business
                       and configured.service_id=v_appointment.service_id)
         or exists(select 1 from public.service_branches allowed
                    where allowed.business_id=p_business
                      and allowed.service_id=v_appointment.service_id
                      and allowed.branch_id=v_appointment.branch_id)
       )
  ) then
    raise exception 'appointment service is not active at this branch' using errcode='22023';
  end if;
  if not exists(
    select 1 from public.staff staff
    join public.staff_branches staff_branch
      on staff_branch.business_id=staff.business_id and staff_branch.staff_id=staff.id
     and staff_branch.branch_id=v_appointment.branch_id
   where staff.id=p_staff and staff.business_id=p_business and staff.active
  ) then
    raise exception 'assigned staff must be active at this branch' using errcode='22023';
  end if;
  if v_appointment.starts_at=p_starts and v_appointment.ends_at=v_ends
     and v_appointment.staff_id is not distinct from p_staff
     and v_appointment.note is not distinct from v_note then
    raise exception 'choose a different date, time, duration, staff member or note'
      using errcode='22023';
  end if;

  -- Join v47's exact per-business scheduling lock domain. New bookings and every
  -- reschedule therefore serialize their final availability check and mutation.
  perform pg_advisory_xact_lock(hashtextextended(p_business::text,47));

  if not app.staff_free_for_appointment_v47(
    p_business,p_staff,v_appointment.branch_id,v_appointment.service_id,
    p_starts,v_ends,p_appointment
  ) then
    v_suggestions:=app.suggest_appointment_reschedule_v48(
      p_business,p_appointment,v_appointment.branch_id,v_appointment.service_id,
      p_starts,p_duration_minutes,5
    );
    v_response:=jsonb_build_object(
      'status','conflict','replayed',false,'appointment_id',p_appointment,
      'notification_state','not_applicable','suggestions',v_suggestions
    );
    insert into app.appointment_reschedule_operations(
      business_id,idempotency_key,request_hash,appointment_id,actor,
      old_starts_at,old_ends_at,old_staff_id,requested_starts_at,requested_ends_at,
      requested_staff_id,outcome,notification_state,response
    ) values (
      p_business,p_idempotency_key,v_request_hash,p_appointment,v_actor,
      v_appointment.starts_at,v_appointment.ends_at,v_appointment.staff_id,
      p_starts,v_ends,p_staff,'conflict','not_applicable',v_response
    );
    return v_response;
  end if;

  update public.appointments
     set starts_at=p_starts,ends_at=v_ends,staff_id=p_staff,note=v_note
   where id=p_appointment and business_id=p_business;

  if app.platform_feature_enabled('customer_in_app_inbox') then
    v_notification_state:='not_applicable';
    select link.* into v_link from public.customer_links link
     where link.business_id=p_business and link.client_id=v_appointment.client_id
       and link.state='verified' order by link.verified_at desc,link.id limit 1;
    if found then
      select identity.* into v_identity from public.customer_identities identity
       where identity.id=v_link.identity_id and identity.auth_user_id=v_link.auth_user_id
         and identity.status='active';
      if found then
        if exists(
          select 1 from public.customer_notification_preferences preference
           where preference.business_id=p_business and preference.identity_id=v_identity.id
             and preference.auth_user_id=v_identity.auth_user_id
             and preference.link_id=v_link.id and preference.client_id=v_appointment.client_id
             and preference.channel='in_app' and preference.topic='booking_updates'
             and preference.opted_in
        ) then
          v_source_fingerprint:=app.c46_sha256_hex(jsonb_build_object(
            'appointment_id',p_appointment,'starts_at',p_starts,'ends_at',v_ends
          )::text);
          v_dedupe_key:=app.c46_sha256_hex(jsonb_build_object(
            'identity_id',v_identity.id,'source_kind','v48_appointment_reschedule',
            'source_fingerprint',v_source_fingerprint,'idempotency_key',p_idempotency_key
          )::text);
          insert into public.customer_in_app_inbox_events(
            business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,
            route_key,source_fingerprint,dedupe_key,title,body,deadline_at
          ) values (
            p_business,v_identity.id,v_identity.auth_user_id,v_link.id,
            v_appointment.client_id,'v48_appointment_reschedule','booking_updates',
            'wallet_business',v_source_fingerprint,v_dedupe_key,'Appointment time changed',
            'Open this business wallet to review your updated appointment.',p_starts
          ) on conflict (identity_id,dedupe_key) do nothing;
          v_notification_state:='in_app_created';
        else
          v_notification_state:='suppressed';
        end if;
      end if;
    end if;
  end if;

  v_response:=jsonb_build_object(
    'status','rescheduled','replayed',false,'appointment_id',p_appointment,
    'starts_at',p_starts,'ends_at',v_ends,'staff_id',p_staff,
    'notification_state',v_notification_state
  );
  insert into app.appointment_reschedule_operations(
    business_id,idempotency_key,request_hash,appointment_id,actor,
    old_starts_at,old_ends_at,old_staff_id,requested_starts_at,requested_ends_at,
    requested_staff_id,outcome,notification_state,response
  ) values (
    p_business,p_idempotency_key,v_request_hash,p_appointment,v_actor,
    v_appointment.starts_at,v_appointment.ends_at,v_appointment.staff_id,
    p_starts,v_ends,p_staff,'rescheduled',v_notification_state,v_response
  );
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (p_business,v_actor,'APPOINTMENT_RESCHEDULE_V48','appointments',p_appointment,
    jsonb_build_object(
      'from_starts_at',v_appointment.starts_at,'to_starts_at',p_starts,
      'from_ends_at',v_appointment.ends_at,'to_ends_at',v_ends,
      'from_staff_id',v_appointment.staff_id,'to_staff_id',p_staff,
      'notification_state',v_notification_state,'idempotency_key',p_idempotency_key
    ));
  return v_response;
end
$$;

revoke all privileges on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid)
  to authenticated;

notify pgrst, 'reload schema';

commit;
