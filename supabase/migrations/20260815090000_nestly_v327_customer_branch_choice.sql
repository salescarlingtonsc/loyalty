-- v327 — customer-chosen branch for multi-branch bookings
--
-- Owner directive (2026-08-14, peekaa.asia customer app booking flow): for a business with
-- more than one branch, the public booking wizard jumped straight from Service to Team with no
-- way to say WHICH branch. The Team step then also needs to only offer staff assigned to that
-- branch — "relevant staff pulled per branch".
--
-- Design notes
--  * Mirrors v183 exactly: bookable staff are a server-validated identity list, not a free
--    text field, and branch choice gets the same shape — a real, server-validated branches[]
--    array on the page projection, and a branch_id re-validated on submit.
--  * The branch step only appears for a business with MORE THAN ONE active branch — a
--    single-branch business (still most of them) sees no new step and no branch identity is
--    exposed on its public page at all. Same "off by default, exposes nothing" contract v183
--    set for staff choice.
--  * app.v183_bookable_staff() gains a p_branch filter using the SAME staff_branches exact-
--    match convention every staff-side branch scoping function already uses (see v120's
--    create_staff_blocked_time_v120: `exists (select 1 from staff_branches where ... and
--    branch_id = p_branch)`), not the "unassigned = anyone" fallback staff_services uses —
--    staff_branches is populated for every staff member at creation (v11a backfill plus every
--    onboarding/invite path since), so there is no legitimate "nobody assigned yet" case to
--    fall through for.
--  * booking_requests.branch_id records what the CUSTOMER asked for, exactly like the existing
--    booking_requests.staff_id column from v183. staff_decide_booking_request_v73 already takes
--    an explicit p_branch override for the staff member confirming the request; that override
--    keeps priority, but when staff leaves it unset the request's own branch_id is now the
--    fallback instead of silently landing on "whichever branch is default" — the same
--    "customer picked X but the business saw something else" gap v183 closed for staff choice,
--    here for branch choice.

begin;

alter table public.booking_requests add column if not exists branch_id uuid;
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.booking_requests'::regclass
       and conname = 'booking_requests_branch_id_fkey'
  ) then
    alter table public.booking_requests
      add constraint booking_requests_branch_id_fkey
      foreign key (branch_id) references public.branches(id) on delete set null;
  end if;
end $$;
comment on column public.booking_requests.branch_id is
  'v327: the branch the CUSTOMER asked for. The business remains free to confirm into a
   different branch when it approves the request.';

-- 1. Bookable-staff resolver gains a branch filter -----------------------------------------
drop function if exists app.v183_bookable_staff(uuid, uuid, uuid);

create or replace function app.v183_bookable_staff(
  p_business uuid, p_service uuid, p_staff uuid, p_branch uuid default null
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
     and (
       p_branch is null
       or exists (
         select 1 from public.staff_branches assignment
          where assignment.business_id = p_business
            and assignment.staff_id = member.id
            and assignment.branch_id = p_branch
       )
     )
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

revoke all on function app.v183_bookable_staff(uuid, uuid, uuid, uuid) from public;
revoke all on function app.v183_bookable_staff(uuid, uuid, uuid, uuid) from anon;
revoke all on function app.v183_bookable_staff(uuid, uuid, uuid, uuid) from authenticated;

-- 2. Availability engine: thread branch through the roster AND the branch-hours lookup -----
drop function if exists public.internal_public_booking_availability(text, uuid, uuid, date, integer);

create or replace function public.internal_public_booking_availability(
  p_slug text,
  p_service uuid,
  p_staff uuid,
  p_from date,
  p_days integer,
  p_branch uuid default null
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
    -- Per-person working window for that weekday: their own rota if they have one at all,
    -- otherwise the branch opening hours. A person WITH a rota who is not rostered that day
    -- has no window, which is the point of a rota. When the customer picked a branch, the shop
    -- fallback is THAT branch's hours, not whichever branch happens to sort first.
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

revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) from public;
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) from anon;
revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) from authenticated;
grant execute on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid) to service_role;

-- 3. Booking page projection: expose branches[] and per-staff branch_ids -------------------
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
  v_branches jsonb := '[]'::jsonb;
  v_branch_count integer;
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

  select count(*) into v_branch_count
    from public.branches branch
   where branch.business_id = v_business.id and branch.active;

  -- v327: branch identity is exposed only when there is a real choice to make. A single-branch
  -- business (still most of them) gets no new step and no branch data on the page at all — the
  -- same "off by default, exposes nothing" contract v183 set for staff choice.
  if v_branch_count > 1 then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', branch.id, 'name', coalesce(nullif(btrim(branch.name), ''), 'Branch')
           ) order by branch.is_default desc nulls last, lower(branch.name), branch.id), '[]'::jsonb)
      into v_branches
      from public.branches branch
     where branch.business_id = v_business.id and branch.active;
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
             ), '[]'::jsonb),
             'branch_ids', coalesce((
               select jsonb_agg(assignment.branch_id order by assignment.branch_id)
                 from public.staff_branches assignment
                where assignment.business_id = v_business.id
                  and assignment.staff_id = member.id
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
    'staff', v_staff,
    'branches', v_branches
  );
exception when others then
  return null;
end;
$$;

revoke all on function public.internal_public_booking_page(text) from public;
revoke all on function public.internal_public_booking_page(text) from anon;
revoke all on function public.internal_public_booking_page(text) from authenticated;
grant execute on function public.internal_public_booking_page(text) to service_role;

-- 4. Submit: validate and record the requested branch --------------------------------------
drop function if exists public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid
);

create or replace function public.internal_public_booking_submit(
  p_slug text, p_name text, p_email text, p_phone text, p_service uuid,
  p_party integer, p_preferred timestamptz, p_notes text, p_table_type uuid,
  p_consent boolean, p_token_hash text, p_idempotency_hash text,
  p_request_fingerprint text, p_authenticated_user uuid, p_staff uuid,
  p_branch uuid default null
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
  -- The staff/branch preference is validated BEFORE the shared submit path runs, so an
  -- invalid or foreign id is rejected outright rather than silently dropped.
  if p_staff is not null or p_branch is not null then
    select business.id into v_business_id
      from public.businesses business
     where business.slug = p_slug
     limit 1;
    if v_business_id is null then
      raise exception 'invalid request' using errcode = '22023';
    end if;
  end if;

  if p_staff is not null then
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
         and (p_branch is null or exists (
           select 1 from public.staff_branches assignment
            where assignment.business_id = v_business_id
              and assignment.staff_id = p_staff
              and assignment.branch_id = p_branch
         ))
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

  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
     where branch_row.id = p_branch
       and branch_row.business_id = v_business_id
       and branch_row.active
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  select public.internal_public_booking_submit(
    p_slug, p_name, p_email, p_phone, p_service, p_party, p_preferred,
    p_notes, p_table_type, p_consent, p_token_hash, p_idempotency_hash,
    p_request_fingerprint, p_authenticated_user
  ) into v_result;

  if (p_staff is null and p_branch is null) or v_result is null
     or coalesce((v_result->>'conflict')::boolean, false)
     or coalesce((v_result->>'replayed')::boolean, false) then
    return v_result;
  end if;

  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;

  if v_request is not null then
    update public.booking_requests
       set staff_id = case when p_staff is not null then p_staff else staff_id end,
           branch_id = case when p_branch is not null then p_branch else branch_id end
     where id = v_request
       and business_id = v_business_id;
  end if;
  if v_appointment is not null then
    -- An auto-confirmed booking becomes an appointment immediately; the request is what the
    -- customer asked for, so the staff assignment is only applied when the slot is still
    -- unassigned. The branch was just created moments ago in this same transaction by the
    -- default-branch trigger and nothing else has had a chance to touch it yet, so the branch
    -- the customer asked for can simply overwrite it outright.
    if p_staff is not null then
      update public.appointments
         set staff_id = p_staff
       where id = v_appointment
         and business_id = v_business_id
         and staff_id is null;
    end if;
    if p_branch is not null then
      update public.appointments
         set branch_id = p_branch
       where id = v_appointment
         and business_id = v_business_id;
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from public;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from anon;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from authenticated;
grant execute on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) to service_role;

-- 5. Manual confirm: honour the customer's own branch choice when staff leaves the override
--    unset. staff_decide_booking_request_v73_v94_base (the v94-renamed body of the original
--    v73 function) is NOT touched — it already takes p_branch as a concrete, already-resolved
--    branch. The resolution happens one level up, in app.require_branch_module_v94, called
--    from the public wrapper BEFORE the base function ever runs: a null p_branch there was
--    always resolved to "whichever active branch sorts first", so patching the base function
--    would have been dead code — require_branch_module_v94 never forwards a null branch. The
--    fix belongs in the wrapper: substitute the booking request's own branch_id in place of a
--    null staff override before that resolution runs, so require_branch_module_v94 validates
--    and returns the CUSTOMER's branch instead of the shop default. An explicit staff-supplied
--    p_branch still wins outright, exactly as before.
create or replace function public.staff_decide_booking_request_v73(
  p_business uuid,p_request uuid,p_decision text,p_branch uuid default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_branch uuid;
  v_customer_branch uuid;
begin
  if p_branch is null then
    select request.branch_id into v_customer_branch
      from public.booking_requests request
     where request.id=p_request and request.business_id=p_business;
  end if;
  v_branch:=app.require_branch_module_v94(
    p_business,coalesce(p_branch,v_customer_branch),'bookings','rw'
  );
  if p_decision='confirm' then
    perform app.require_branch_module_v94(
      p_business,v_branch,'appointments','rw'
    );
  end if;
  return public.staff_decide_booking_request_v73_v94_base(
    p_business,p_request,p_decision,v_branch
  );
end
$$;

revoke all on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) to authenticated;

commit;
