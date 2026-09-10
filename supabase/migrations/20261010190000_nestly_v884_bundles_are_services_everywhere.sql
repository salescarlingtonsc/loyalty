-- nestly_v884 — a bundle is a service everywhere: no differentiation.
--
-- OWNER, 2026-09-10: "make sure that bundle also act like a services - no differentiation."
--
-- v882 made bundles bookable from the customer page but kept them a special case on every other
-- path: the staff New-appointment form could not book one, auto-approve left them for a human,
-- the scheduler and both staff-free checks refused a bundle id in the service position, the
-- suggestion RPC called it "not bookable at this branch", completion wrote no member lines and
-- deducted no consumables, and every customer-facing reader (appointments page, booking requests,
-- Book again, the manage-booking lookup, the WhatsApp confirmation) printed a NULL name.
--
-- ONE RESOLVER. app.booking_item_v884(business, id) answers "what is this id" — a service or a
-- bundle — with the name, the duration (a bundle's = the sum of its service members, v882's
-- authority), the buffers (summed for a bundle), and the price. app.staff_can_do_item_v884 is
-- the one assignment rule: a service with assignments needs one of its people; a bundle needs
-- someone assigned to every member service that has assignments; unassigned = anyone. Every
-- function below reads through those two, so the id in the "service" position may name a
-- bundle and nothing downstream can tell the difference:
--   * book_appointment_smart_v47_v94_base (the staff form, Move & confirm, the manual confirm
--     path all end here): a bundle books one appointment, bundle_id stamped, priced at the
--     bundle, note "Bundle: <name>";
--   * app.staff_free_for_appointment_v120_base / _v47: buffers and assignment via the resolver;
--   * suggest_appointment_staff_v47_v94_base: a bundle is bookable at any branch;
--   * app.v660_autoapprove_booking_request: a bundle request auto-approves like a service one;
--   * app.on_appointment_completed: a completed bundle appointment itemises exactly as the till
--     does (app.ps1c_bundle_lines_v204 — one line per member carrying bundle_id, so v825
--     commission and v455 product stock apply), and every member service's consumables are
--     deducted;
--   * customer_get_appointments_page, customer_get_booking_requests, internal_public_booking_lookup,
--     app.whatsapp_enqueue_appointment_notice_v557: service_name is the service's or the bundle's;
--   * customer_get_repeat_booking_preference_v167 ("Book again"): a bundle appointment repeats as
--     the bundle — the booking page lists both, and its repeat_service parameter accepts either id.
-- Not changed: get_ci_rebooking_v1 (an analytics composition keyed on service_id; a separate
-- question). Grants restate every replaced function's live proacl verbatim.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. one resolver: an id in the service position is a service or a bundle, nobody else asks
-- ---------------------------------------------------------------------------------------------
create or replace function app.booking_item_v884(p_business uuid, p_item uuid)
returns table(kind text, service_id uuid, bundle_id uuid, name text, duration_min integer,
              buffer_before_min integer, buffer_after_min integer, price_cents integer)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select 'service', s.id, null::uuid, s.name, coalesce(s.duration_min, 60),
         coalesce(s.buffer_before_min, 0), coalesce(s.buffer_after_min, 0), coalesce(s.price_cents, 0)
    from public.services s
   where s.id = p_item and s.business_id = p_business and s.active
  union all
  select 'bundle', null::uuid, b.id, b.name, app.bundle_booking_duration_v882(p_business, b.id),
         coalesce((select sum(coalesce(m.buffer_before_min, 0))::integer
                     from public.bundle_items bi join public.services m
                       on m.id = bi.service_id and m.business_id = p_business and m.active
                    where bi.bundle_id = b.id), 0),
         coalesce((select sum(coalesce(m.buffer_after_min, 0))::integer
                     from public.bundle_items bi join public.services m
                       on m.id = bi.service_id and m.business_id = p_business and m.active
                    where bi.bundle_id = b.id), 0),
         coalesce(b.price_cents, 0)
    from public.bundles b
   where b.id = p_item and b.business_id = p_business and b.active
     and app.bundle_booking_duration_v882(p_business, b.id) is not null
   limit 1
$$;
revoke all on function app.booking_item_v884(uuid, uuid) from public, anon, authenticated;

-- the staff-assignment rule, once: a service with assignments needs one of its people; a bundle
-- needs a person assigned to EVERY member service that has assignments (unassigned = anyone).
create or replace function app.staff_can_do_item_v884(p_business uuid, p_staff uuid, p_item uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select not exists (
    select 1
      from (
        select p_item as service_id
         where exists (select 1 from public.services s where s.id = p_item and s.business_id = p_business)
        union all
        select bi.service_id
          from public.bundle_items bi
          join public.bundles b on b.id = bi.bundle_id and b.business_id = p_business
         where bi.bundle_id = p_item and bi.service_id is not null
      ) needed
     where exists (select 1 from public.staff_services configured
                    where configured.business_id = p_business and configured.service_id = needed.service_id)
       and not exists (select 1 from public.staff_services qualified
                        where qualified.business_id = p_business and qualified.staff_id = p_staff
                          and qualified.service_id = needed.service_id)
  )
$$;
revoke all on function app.staff_can_do_item_v884(uuid, uuid, uuid) from public, anon, authenticated;

-- 2. the scheduler
CREATE OR REPLACE FUNCTION public.book_appointment_smart_v47_v94_base(p_business uuid, p_client uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_duration_minutes integer, p_requested_staff uuid, p_assignment_mode text, p_note text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_request_hash text;
  v_existing app.appointment_booking_operations%rowtype;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_item record;                        -- nestly_v884
  v_item_service uuid; v_item_bundle uuid; v_item_name text; v_item_price integer := 0; -- nestly_v884
  v_staff public.staff%rowtype;
  v_duration integer;
  v_ends timestamptz;
  v_suggestions jsonb;
begin
  if auth.uid() is null
     or (case
       when app.business_has_appointments_module_v288(p_business, p_branch)
         then not app.can_module_write(p_business, 'appointments')
         else not app.can_module_write(p_business, 'bookings')
     end)
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
    -- nestly_v884 (owner: "bundle also act like a service — no differentiation"): the id in the
    -- service position resolves to a service OR a bundle through the one resolver; a bundle books
    -- one appointment for its summed duration at its own price, with its name in the note.
    select * into v_item from app.booking_item_v884(p_business, p_service);
    if not found then raise exception 'active service not found' using errcode='22023'; end if;
    if v_item.kind = 'service' then
      select * into v_service from public.services s
       where s.id=p_service and s.business_id=p_business and s.active;
      if exists(select 1 from public.service_branches configured
                 where configured.business_id=p_business and configured.service_id=p_service)
         and not exists(select 1 from public.service_branches allowed
                         where allowed.business_id=p_business and allowed.service_id=p_service
                           and allowed.branch_id=p_branch) then
        raise exception 'service is not bookable at this branch' using errcode='22023';
      end if;
    end if;
    v_duration := v_item.duration_min;
    v_item_service := v_item.service_id; v_item_bundle := v_item.bundle_id;
    v_item_name := v_item.name; v_item_price := v_item.price_cents;
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
    business_id,client_id,branch_id,service_id,bundle_id,staff_id,starts_at,ends_at,
    note,total_cents,source,status
  ) values (
    p_business,p_client,p_branch,v_item_service,v_item_bundle,v_staff.id,p_starts,v_ends,
    case when v_item_bundle is not null
         then concat_ws(' — ', 'Bundle: ' || v_item_name, nullif(btrim(coalesce(p_note,'')),''))
         else nullif(btrim(coalesce(p_note,'')),'') end,
    coalesce(v_item_price,0),
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
$function$;
revoke all on function public.book_appointment_smart_v47_v94_base(uuid, uuid, uuid, uuid, timestamptz, integer, uuid, text, text, text) from public, anon, authenticated, service_role;

-- 3. the two staff-free checks
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
    -- nestly_v884: a service or a bundle (summed buffers), through the one resolver.
    select item.buffer_before_min, item.buffer_after_min
      into v_buffer_before, v_buffer_after
      from app.booking_item_v884(p_business, p_service) item;
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
     and not app.staff_can_do_item_v884(p_business, p_staff, p_service) then return false; end if;

  if exists (
    select 1 from public.staff_off_days off_day
     where off_day.business_id = p_business and off_day.staff_id = p_staff
       and v_local_start::date between off_day.starts_on and off_day.ends_on
  ) then return false; end if;

  if exists (
    select 1 from public.staff_recurring_off_days recurring
     where recurring.business_id = p_business and recurring.staff_id = p_staff
       and recurring.weekday = v_weekday
  ) then return false; end if;

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

  -- v759: this team member's OWN repeating break.
  if exists (
    select 1 from public.staff_recurring_breaks pause
     where pause.business_id = p_business and pause.staff_id = p_staff
       and pause.weekday = v_weekday
       and pause.starts_at < v_local_end::time
       and pause.ends_at > v_local_start::time
  ) then return false; end if;

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
revoke all on function app.staff_free_for_appointment_v120_base(uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
grant execute on function app.staff_free_for_appointment_v120_base(uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid) to service_role;
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

  -- v611: the shop's opening hours are every teammate's default (the owner ruling nestly_v598
  -- implemented for the CUSTOMER slot function, now honoured by the write-time guard too).
  -- A personal staff_hours row governs the weekday it names; a weekday with NO personal row
  -- falls back to the branch hours checked just above. Explicit absence stays explicit:
  -- staff_recurring_off_days / staff_off_days / blocked times keep refusing via the v383 checks
  -- in staff_free_for_appointment_v120_base and the blocked-times clause below.
  if v_local_end::date<>v_local_start::date
     or not exists (
       select 1 from public.branch_hours hours
        where hours.business_id=p_business and hours.branch_id=p_branch
          and hours.weekday=v_weekday
          and v_local_start::time>=hours.opens_at
          and v_local_end::time<=hours.closes_at
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
revoke all on function app.staff_free_for_appointment_v47(uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

-- 4. the suggestion RPC
CREATE OR REPLACE FUNCTION public.suggest_appointment_staff_v47_v94_base(p_business uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_duration_minutes integer, p_limit integer DEFAULT 5, p_recent_days integer DEFAULT 30, p_staff uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_recent_days integer := coalesce(p_recent_days, 30);
  v_ends timestamptz;
  v_timezone text;
  v_day_end timestamptz;
  v_candidate timestamptz;
  v_available jsonb := '[]'::jsonb;
  v_next jsonb := '[]'::jsonb;
  v_staff record;
begin
  if v_recent_days not in (1, 3, 7, 30) then
    raise exception 'unsupported_recent_window' using errcode='22023';
  end if;
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
  -- nestly_v884: the id may name a bundle; a bundle has no branch restriction of its own.
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
  ) and not exists(
    select 1 from app.booking_item_v884(p_business, p_service) item where item.kind = 'bundle'
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
                 and a.starts_at >= now() - make_interval(days => v_recent_days)) as recent_appointments,
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
       and (p_staff is null or s.id = p_staff)
       and app.staff_free_for_appointment_v47(
             p_business,s.id,p_branch,p_service,v_candidate,
             v_candidate + make_interval(mins => p_duration_minutes),null)
     order by
       (select count(*) from public.appointments a
         where a.business_id=p_business and a.staff_id=s.id
           and a.status in ('booked','completed')
           and a.starts_at >= now() - make_interval(days => v_recent_days)),
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
$function$;
revoke all on function public.suggest_appointment_staff_v47_v94_base(uuid, uuid, uuid, timestamptz, integer, integer, integer, uuid) from public, anon, authenticated;
grant execute on function public.suggest_appointment_staff_v47_v94_base(uuid, uuid, uuid, timestamptz, integer, integer, integer, uuid) to service_role;

-- 5. auto-approve
CREATE OR REPLACE FUNCTION app.v660_autoapprove_booking_request(p_request uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_req public.booking_requests%rowtype;
  v_business public.businesses%rowtype;
  v_service public.services%rowtype;
  v_item record;              -- nestly_v884
  v_item_id uuid;             -- nestly_v884
  v_branch uuid;
  v_staff uuid;
  v_client uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_duration integer;
  v_appointment uuid;
begin
  select * into v_req from public.booking_requests where id = p_request for update;
  if not found then return null; end if;
  -- Only an unanswered request is a candidate. A row already confirmed, declined, cancelled or
  -- carrying an appointment is somebody's decision and is never revisited.
  if v_req.status not in ('new','pending','waitlisted') or v_req.appointment_id is not null then
    return null;
  end if;

  select * into v_business from public.businesses where id = v_req.business_id;
  if not found or not coalesce(v_business.auto_approve_changes, false) then return null; end if;

  -- A table/party request without a service has no duration and no staff to check; it keeps the
  -- capacity path it already had.
  -- nestly_v884: a bundle request is auto-approved exactly like a service request.
  v_item_id := coalesce(v_req.service_id, v_req.bundle_id);
  if v_item_id is null or v_req.preferred_at is null then return null; end if;
  v_starts := v_req.preferred_at;
  if v_starts <= now() then return null; end if;

  select * into v_item from app.booking_item_v884(v_req.business_id, v_item_id);
  if not found then return null; end if;
  v_duration := greatest(coalesce(v_item.duration_min, 60), 5);
  v_ends := v_starts + make_interval(mins => v_duration);

  v_branch := coalesce(v_req.branch_id, app.default_branch(v_req.business_id));
  if v_branch is null then return null; end if;

  -- The slot must not already be claimed by ANOTHER unanswered request. app.staff_free_for_appointment_v47
  -- does not consider booking_requests; the day-lister does, and auto-approve must agree with the
  -- day-lister or it becomes a way to double-book.
  if exists (
    select 1 from public.booking_requests other
     where other.business_id = v_req.business_id
       and other.id <> v_req.id
       and other.status in ('new','pending','waitlisted')
       and other.appointment_id is null
       and other.preferred_at is not null
       and coalesce(other.branch_id, v_branch) = v_branch
       and (v_req.staff_id is null or other.staff_id is null or other.staff_id = v_req.staff_id)
       and other.preferred_at < v_ends
       and other.preferred_at + make_interval(mins => v_duration) > v_starts
  ) then
    return null;
  end if;

  -- The team member the customer asked for, if they asked and are still free; otherwise the first
  -- bookable one who is. Deterministic order, so the same request always resolves the same way.
  if v_req.staff_id is not null
     and app.staff_free_for_appointment_v47(v_req.business_id, v_req.staff_id, v_branch,
           v_item_id, v_starts, v_ends, null) then
    v_staff := v_req.staff_id;
  elsif v_req.staff_id is null then
    select candidate.staff_id into v_staff
      from app.v183_bookable_staff(v_req.business_id, v_req.service_id, null, v_branch) candidate
     where app.staff_free_for_appointment_v47(v_req.business_id, candidate.staff_id, v_branch,
             v_item_id, v_starts, v_ends, null)
     order by candidate.staff_id
     limit 1;
  end if;
  if v_staff is null then return null; end if;

  /* nestly_v806: public.appointments.client_id is NOT NULL, and a GUEST request carries no
     customer_client_id. Resolve the customer exactly as the manual confirmation does
     (public.staff_decide_booking_request_v73_v94_base) and as public.request_booking's own
     auto-confirm branch does — match an existing customer on normalised phone or email first,
     create one only when neither matches, and apply the booking's marketing consent only to a
     customer this filing actually created. Without this the insert below raised 23502 and both
     callers swallowed it, so guest auto-approve silently never happened. */
  if v_req.customer_client_id is not null then
    v_client := v_req.customer_client_id;
  else
    v_client := app.upsert_portal_client(v_req.business_id, v_req.name, v_req.phone, v_req.email);
    perform app.apply_booking_consent(v_req.business_id, v_client, v_req.marketing_consent);
  end if;
  if v_client is null then
    /* Fail closed, and say so. The request stays pending for a human rather than dying inside a
       caller's `exception when others then null`. */
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(v_req.business_id, null, 'booking_request.auto_approve_skipped_v806',
      'booking_requests', v_req.id,
      jsonb_build_object('reason', 'client_unresolved', 'staff_id', v_staff,
                         'branch_id', v_branch, 'starts_at', v_starts));
    return null;
  end if;

  insert into public.appointments(business_id, client_id, staff_id, starts_at, ends_at, status,
    party_size, source, service_id, bundle_id, total_cents, note, branch_id)
  values(v_req.business_id, v_client, v_staff, v_starts, v_ends, 'booked',
    greatest(coalesce(v_req.party_size, 1), 1), 'portal', v_item.service_id, v_item.bundle_id,
    v_item.price_cents,
    case when v_item.bundle_id is not null
         then concat_ws(' — ', 'Bundle: ' || v_item.name, nullif(btrim(coalesce(v_req.notes, '')), ''))
         else v_req.notes end,
    v_branch)
  returning id into v_appointment;

  update public.booking_requests
     set status = 'confirmed', appointment_id = v_appointment, expires_at = null
   where id = v_req.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(v_req.business_id, null, 'booking_request.auto_approved_v660', 'booking_requests', v_req.id,
    jsonb_build_object('appointment_id', v_appointment, 'staff_id', v_staff, 'branch_id', v_branch,
                       'starts_at', v_starts, 'service_id', v_req.service_id,
                       'requested_staff', v_req.staff_id, 'client_id', v_client,
                       'guest', v_req.customer_client_id is null));

  return v_appointment;
end
$function$;
revoke all on function app.v660_autoapprove_booking_request(uuid) from public, anon, authenticated;

-- 6. completion
CREATE OR REPLACE FUNCTION app.on_appointment_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_amount integer;
  v_sale_id uuid;
  v_component record;
  v_batch record;
  v_need integer;
  v_take integer;
  v_staff uuid;
  v_lines jsonb;        -- nestly_v884
  v_line jsonb;         -- nestly_v884
  v_member uuid;        -- nestly_v884
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
    ) on conflict do nothing returning id into v_sale_id;
    if v_sale_id is not null and new.bundle_id is not null then
      -- nestly_v884: a completed bundle appointment itemises exactly as the till does — one line
      -- per member through the same allocator (app.ps1c_bundle_lines_v204), each carrying the
      -- bundle id, so commission (v825) and product stock (v455) follow the same rules.
      v_lines := app.ps1c_bundle_lines_v204(new.business_id, new.bundle_id, 1);
      if coalesce(v_lines->>'status','') = 'ok' then
        for v_line in select * from jsonb_array_elements(v_lines->'lines') loop
          insert into public.sale_items(sale_id, business_id, item_type, ref_id, product_id, bundle_id,
                                        description, qty, unit_cents, line_cents, staff_id)
          values (v_sale_id, new.business_id,
                  case when v_line->>'kind' = 'service' then 'service' else 'retail' end,
                  (v_line->>'item_id')::uuid,
                  case when v_line->>'kind' = 'product' then (v_line->>'item_id')::uuid end,
                  new.bundle_id, v_line->>'name', 1,
                  (v_line->>'line_cents')::integer, (v_line->>'line_cents')::integer, v_staff);
        end loop;
      else
        insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents, staff_id)
        values (v_sale_id, new.business_id, 'service', null, new.bundle_id,
                coalesce((select b.name from public.bundles b where b.id = new.bundle_id), 'appointment bundle'),
                1, v_amount, v_amount, v_staff);
      end if;
    elsif v_sale_id is not null then
      insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, staff_id)
      values (v_sale_id, new.business_id, 'service', new.service_id,
              coalesce((select srv.name from public.services srv where srv.id = new.service_id), 'appointment service'),
              1, v_amount, v_amount, v_staff);
    end if;
    -- consumables: the service's own components, or every member service's components for a bundle
    for v_member in
      select new.service_id where new.service_id is not null
      union all
      select bi.service_id from public.bundle_items bi
       where new.bundle_id is not null and bi.bundle_id = new.bundle_id and bi.service_id is not null
    loop
      for v_component in select product_id,qty from public.service_products
        where service_id=v_member loop
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
    end loop;
  end if;
  return new;
end
$function$;
revoke all on function app.on_appointment_completed() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 7. customer-facing readers
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_get_appointments_page(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_as_of timestamptz := statement_timestamp();
  v_cursor_group integer;
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key)
              where key not in ('limit','as_of','sort_group','starts_at','id')) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_as_of := coalesce(nullif(v_cursor->>'as_of', '')::timestamptz, v_as_of);
    v_cursor_group := nullif(v_cursor->>'sort_group', '')::integer;
    v_cursor_at := nullif(v_cursor->>'starts_at', '')::timestamptz;
    v_cursor_id := nullif(v_cursor->>'id', '')::uuid;
  exception when others then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end;
  if v_cursor_group is not null and v_cursor_group not in (0,1) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if num_nonnulls(v_cursor_group,v_cursor_at,v_cursor_id) not in (0,3) then
    raise exception 'appointments cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('appointments' = any(v_context.enabled_modules)) then
    raise exception 'appointments module is unavailable for this business' using errcode = '42501';
  end if;

  with ordered as (
    select a.id, a.starts_at, a.ends_at, a.status,
           case when a.status = 'booked' and a.starts_at >= v_as_of then 0 else 1 end as sort_group,
           coalesce(s.name, bundle.name) as service_name, br.name as branch_name, nullif(btrim(br.address), '') as branch_address,
           nullif(btrim(br.phone), '') as branch_phone
      from public.appointments a
      left join public.services s on s.id = a.service_id and s.business_id = a.business_id
      left join public.bundles bundle on bundle.id = a.bundle_id and bundle.business_id = a.business_id -- nestly_v884
      left join public.branches br on br.id = a.branch_id and br.business_id = a.business_id
     where a.business_id = v_context.business_id
       and a.client_id = v_context.client_id
       and a.status in ('booked','completed','cancelled','no_show')
  ), eligible as (
    select * from ordered
     where v_cursor_group is null
        or sort_group > v_cursor_group
        or (
          sort_group = v_cursor_group and (
            (sort_group = 0 and (starts_at,id) > (v_cursor_at,v_cursor_id))
            or (sort_group = 1 and (starts_at,id) < (v_cursor_at,v_cursor_id))
          )
        )
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit + 1
  ), visible as (
    select * from eligible
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'appointment_id', id, 'starts_at', starts_at, 'ends_at', ends_at,
      'status', status, 'service_name', service_name, 'branch_name', branch_name,
      'branch_address', branch_address, 'branch_phone', branch_phone
    ) order by sort_group,
               case when sort_group=0 then starts_at end asc,
               case when sort_group=1 then starts_at end desc,
               case when sort_group=0 then id end asc,
               case when sort_group=1 then id end desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'as_of', v_as_of, 'sort_group', sort_group, 'starts_at', starts_at,
        'id', id, 'limit', v_limit
      ) from visible
       order by sort_group,
                case when sort_group=0 then starts_at end asc,
                case when sort_group=1 then starts_at end desc,
                case when sort_group=0 then id end asc,
                case when sort_group=1 then id end desc
       offset v_limit - 1 limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$function$;
revoke all on function public.customer_get_appointments_page(text, jsonb) from public, anon;
grant execute on function public.customer_get_appointments_page(text, jsonb) to authenticated, service_role;
CREATE OR REPLACE FUNCTION public.customer_get_booking_requests(p_limit integer DEFAULT 20, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer;
  v_cursor_created timestamptz;
  v_cursor_id uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'invalid booking request limit' using errcode = '22023';
  end if;
  v_limit := p_limit;
  if p_cursor is not null then
    if jsonb_typeof(p_cursor) <> 'object'
       or not (p_cursor ? 'created_at')
       or not (p_cursor ? 'request_id')
       or (select count(*) from jsonb_object_keys(p_cursor)) <> 2
       or jsonb_typeof(p_cursor->'created_at') <> 'string'
       or jsonb_typeof(p_cursor->'request_id') <> 'string'
       or (p_cursor->>'created_at') !~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$'
       or (p_cursor->>'request_id') !~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'invalid booking request cursor' using errcode = '22023';
    end if;
    begin
      v_cursor_created := (p_cursor->>'created_at')::timestamptz;
      v_cursor_id := (p_cursor->>'request_id')::uuid;
    exception when others then
      raise exception 'invalid booking request cursor' using errcode = '22023';
    end;
  end if;

  with visible as (
    select request.id,
           business.slug as business_slug,
           business.name as business_name,
           case when request.status = 'new' then 'pending' else request.status end as status,
           request.preferred_at,
           request.party_size,
           coalesce(service.name, bundle.name) as service_name,
           request.created_at
      from public.customer_identities identity
      join public.customer_links link
        on link.identity_id = identity.id
       and link.auth_user_id = identity.auth_user_id
       and link.state = 'verified'
      join public.booking_requests request
        on request.business_id = link.business_id
       and request.customer_client_id = link.client_id
      join app.booking_management_tokens token
        on token.business_id = request.business_id
       and token.booking_request_id = request.id
       and token.customer_client_id = request.customer_client_id
       and token.authenticated_user_id = v_actor
      join public.businesses business on business.id = request.business_id
      left join public.services service
        on service.id = request.service_id
       and service.business_id = request.business_id
      left join public.bundles bundle -- nestly_v884
        on bundle.id = request.bundle_id
       and bundle.business_id = request.business_id
     where identity.auth_user_id = v_actor
       and identity.status = 'active'
       and request.appointment_id is null
       and (
         request.status in ('new', 'pending', 'waitlisted')
         or (
           request.status in ('declined', 'expired', 'cancelled')
           and request.created_at >= current_timestamp - interval '90 days'
         )
       )
       and (
         v_cursor_created is null
         or (request.created_at, request.id) < (v_cursor_created, v_cursor_id)
       )
     order by request.created_at desc, request.id desc
     limit v_limit + 1
  ), listed as (
    select * from visible
     order by created_at desc, id desc
     limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'request_id', listed.id,
        'business_slug', listed.business_slug,
        'business_name', listed.business_name,
        'status', listed.status,
        'preferred_at', listed.preferred_at,
        'party_size', listed.party_size,
        'service_name', listed.service_name,
        'created_at', listed.created_at
      ) order by listed.created_at desc, listed.id desc)
      from listed
    ), '[]'::jsonb),
    'truncated', (select count(*) from visible) > v_limit,
    'next_cursor', case
      when (select count(*) from visible) > v_limit then (
        select jsonb_build_object(
          'created_at', listed.created_at,
          'request_id', listed.id
        )
          from listed
         order by listed.created_at asc, listed.id asc
         limit 1
      )
      else null
    end
  ) into v_result;
  return v_result;
end
$function$;
revoke all on function public.customer_get_booking_requests(integer, jsonb) from public, anon;
grant execute on function public.customer_get_booking_requests(integer, jsonb) to authenticated, service_role;
CREATE OR REPLACE FUNCTION public.customer_get_repeat_booking_preference_v167(p_business_slug text, p_appointment uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_business_slug is null or p_appointment is null then
    raise exception 'invalid repeat booking request' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business_slug', v_context.business_slug,
    'appointment_id', appointment.id,
    'service_id', coalesce(service.id, bundle.id),
    'service_name', coalesce(service.name, bundle.name),
    'staff_id', staff_member.id,
    'staff_name', staff_member.full_name
  ) into v_result
    from public.appointments appointment
    left join public.services service
      on service.business_id = appointment.business_id
     and service.id = appointment.service_id
     and service.active
     and service.show_on_booking_page
    -- nestly_v884: a bundle appointment repeats as the bundle; the booking page lists both.
    left join public.bundles bundle
      on bundle.business_id = appointment.business_id
     and bundle.id = appointment.bundle_id
     and bundle.active
     and app.bundle_booking_duration_v882(bundle.business_id, bundle.id) is not null
    left join public.staff staff_member
      on staff_member.business_id = appointment.business_id
     and staff_member.id = appointment.staff_id
     and staff_member.active
     and appointment.branch_id is not null
     and exists (
       select 1
         from public.staff_branches assignment
        where assignment.business_id = appointment.business_id
          and assignment.branch_id = appointment.branch_id
          and assignment.staff_id = staff_member.id
     )
     and app.staff_can_do_item_v884(appointment.business_id, staff_member.id,
                                    coalesce(appointment.service_id, appointment.bundle_id))
   where appointment.business_id = v_context.business_id
     and (service.id is not null or bundle.id is not null)
     and appointment.client_id = v_context.client_id
     and appointment.id = p_appointment
     and appointment.status = 'completed'
     and appointment.starts_at < statement_timestamp();

  return coalesce(v_result, jsonb_build_object(
    'business_slug', v_context.business_slug,
    'appointment_id', p_appointment,
    'service_id', null,
    'service_name', null,
    'staff_id', null,
    'staff_name', null
  ));
end;
$function$;
revoke all on function public.customer_get_repeat_booking_preference_v167(text, uuid) from public, anon;
grant execute on function public.customer_get_repeat_booking_preference_v167(text, uuid) to authenticated, service_role;
CREATE OR REPLACE FUNCTION public.internal_public_booking_lookup(p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_token app.booking_management_tokens%rowtype;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_token
    from app.booking_management_tokens t
   where t.token_hash = decode(p_token_hash, 'hex')
     and t.revoked_at is null and t.expires_at > clock_timestamp()
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  update app.booking_management_tokens set last_used_at = clock_timestamp()
   where id = v_token.id;

  return (
    select jsonb_build_object(
      'status', coalesce(a.status, br.status),
      'preferred_at', br.preferred_at,
      'starts_at', a.starts_at,
      'service_name', coalesce(s.name, bundle.name),
      'can_change', a.id is not null and a.status = 'booked' and a.starts_at > clock_timestamp(),
      'expires_at', v_token.expires_at)
      from (select 1) seed
      left join public.booking_requests br on br.id = v_token.booking_request_id
      left join public.appointments a on a.id = coalesce(v_token.appointment_id, br.appointment_id)
      left join public.services s on s.id = coalesce(a.service_id, br.service_id)
      left join public.bundles bundle on bundle.id = coalesce(a.bundle_id, br.bundle_id) -- nestly_v884
  );
end;
$function$;
revoke all on function public.internal_public_booking_lookup(text) from public, anon, authenticated;
grant execute on function public.internal_public_booking_lookup(text) to service_role;
CREATE OR REPLACE FUNCTION app.whatsapp_enqueue_appointment_notice_v557(p_business uuid, p_appointment uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_tpl public.whatsapp_template_registry_v551%rowtype;
  v_state jsonb;
  v_quota jsonb;
  v_biz jsonb;
  v_biz_name text;
  v_service_name text;
  v_idem text;
  v_when text;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('appointment_confirmation','appointment_reminder',
                                      'appointment_reminder_short','appointment_updated') then
    return jsonb_build_object('status','refused','reason','unknown_kind');
  end if;

  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','appointment_not_found');
  end if;
  if v_appt.status <> 'booked' then
    return jsonb_build_object('status','refused','reason','appointment_not_booked');
  end if;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  v_biz := app.business_may_initiate_comms_v572(p_business, 'whatsapp', 'transactional');
  if not coalesce((v_biz->>'allowed')::boolean, false) then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_biz->>'reason', 'business_not_eligible'));
  end if;

  -- v581: the template must exist AND be approved. This is what keeps a newly
  -- added kind inert until Meta has actually said yes.
  select * into v_tpl from public.whatsapp_template_registry_v551
   where template_key = p_kind;
  if not found then
    return jsonb_build_object('status','refused','reason','template_unknown');
  end if;
  if v_tpl.status <> 'approved' then
    return jsonb_build_object('status','refused','reason','template_not_approved',
      'template_status', v_tpl.status);
  end if;

  v_state := app.capability_state_v518(p_business, 'whatsapp_appointment_notification');
  if (v_state->>'allowed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_state->>'reason','capability_refused')) || v_state;
  end if;

  -- v583: the owner's own switch, LAST of the eligibility gates and therefore
  -- incapable of overruling any of them. Everything above has already said yes;
  -- this is the shopkeeper's chance to say no.
  if not app.business_automation_enabled_v583(p_business, p_kind) then
    return jsonb_build_object('status','refused','reason','automation_off_for_business',
      'kind', p_kind);
  end if;

  select * into v_client from public.clients
   where id = v_appt.client_id and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','client_not_found');
  end if;
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('status','refused','reason','synthetic_client');
  end if;
  if v_client.phone_norm is null then
    return jsonb_build_object('status','refused','reason','no_phone');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;
  select coalesce(s.name, bundle.name) into v_service_name
    from (select 1) seed
    left join public.services s on s.id = v_appt.service_id
    left join public.bundles bundle on bundle.id = v_appt.bundle_id; -- nestly_v884

  -- A reminder names only a time because its template already says which day.
  -- A confirmation or a change of time must name the date, because the customer
  -- is being told something they do not already know.
  v_when := case
    when p_kind in ('appointment_reminder','appointment_reminder_short')
      then to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'HH12:MI AM')
    else to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM')
  end;

  v_idem := p_kind || ':' || p_appointment::text || ':'
            || to_char(v_appt.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');

  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm,
    template_name, language_code, parameters, idempotency_key,
    status, status_rank, attempt_count, queued_at, next_attempt_at)
  values (
    p_business, p_appointment, p_kind, v_client.phone_norm,
    v_tpl.meta_name, v_tpl.language_code,
    jsonb_build_array(
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_biz_name),''),'Peekaa')),
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_service_name),''),'your appointment')),
      jsonb_build_object('type','text','text', v_when)),
    v_idem, 'queued', app.support_status_rank_v535('queued'), 0, now(), now())
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('status','ok','duplicate',true,'reason','already_queued');
  end if;

  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_appointment_notification', v_idem,
    jsonb_build_object('appointment_id', p_appointment, 'kind', p_kind));

  if (v_quota->>'consumed') is distinct from 'true' then
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(coalesce(v_quota->>'reason','capability_refused'), 64),
           next_attempt_at = null
     where id = v_id;
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_quota->>'reason','capability_refused'),
      'send_id', v_id);
  end if;

  return jsonb_build_object(
    'status','ok','duplicate',false,'send_id',v_id,'kind',p_kind,
    'template_name',v_tpl.meta_name,'idempotency_key',v_idem,
    'remaining', v_quota->'remaining');
end
$function$;
revoke all on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text) from public, anon, authenticated;
grant execute on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text) to service_role;

do $verify$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app' and p.proname in ('booking_item_v884','staff_can_do_item_v884')) <> 2 then
    raise exception 'nestly_v884: resolver functions missing';
  end if;
  if position('booking_item_v884' in pg_get_functiondef('public.book_appointment_smart_v47_v94_base(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure)) = 0
     or position('booking_item_v884' in pg_get_functiondef('app.v660_autoapprove_booking_request(uuid)'::regprocedure)) = 0
     or position('ps1c_bundle_lines_v204' in pg_get_functiondef('app.on_appointment_completed()'::regprocedure)) = 0 then
    raise exception 'nestly_v884: a caller does not read through the resolver';
  end if;
end $verify$;

commit;
