-- nestly_v882 — booking requests: a passed time is a named outcome and ages out; bundles are bookable.
--
-- OWNER, 2026-09-10: "do the two SQL follow-ups for bookings as well. and i need bundle to show
-- for customers to select."
--
-- PART 1 — A REQUEST WHOSE PREFERRED TIME HAS PASSED (AhXiang, photo of 2026-09-08: two New rows
-- preferred 28 Aug and 3 Sep, ticked on 8 Sep, "Confirm failed. appointment start must be in the
-- future"). Three faults stacked:
--   (a) nothing aged the request out — app.expire_stale_bookings keyed on expires_at, which only
--       table-capacity holds set, so a service request stayed New for ever, still counted in the
--       Appointment badge, still offering a tick;
--   (b) the tick could only fail — book_appointment_smart_v47 refuses a start older than five
--       minutes, and staff_decide_booking_request_v73_v94_base let that 22023 escape raw (its
--       handler caught only P0731/exclusion), so staff saw a database sentence with no next step;
--   (c) the rescue existed (staff_reschedule_and_confirm_booking_request_v329) but only the
--       today-forward Appointments views offered it; the Bookings page, the one surface that still
--       showed the row, had no door onto it (closed in the app by nestly_v880).
-- Here: the confirm path returns the structured outcome 'past_start' (pre-checked against the
-- scheduler's own five-minute grace, and translated if the scheduler ever refuses first), and the
-- per-minute sweep expires a service request one day after its preferred time — the day being the
-- window in which Move & confirm can still rescue it, since v329 needs the row to be pending.
--
-- PART 2 — BOOKABLE BUNDLES. public.bundles / bundle_items existed only for the till (v187, v411,
-- v488): no public reader projected them, booking_requests and appointments knew only service_id,
-- and the customer picker listed services alone. Now:
--   * booking_requests.bundle_id and appointments.bundle_id (same-business composite FKs, the v602
--     shape); a request names a service OR a bundle, never both (constraint below);
--   * app.bundle_booking_duration_v882 — the ONE authority for a bundle's slot length: the sum of
--     its active service members' duration_min, NULL when it has none (product members add no
--     time and a product-only bundle is not offered);
--   * internal_public_booking_page projects `bundles[]` (id, name, price_cents, duration_min,
--     items[]) for active bundles with at least one service member;
--   * internal_public_booking_submit gains p_bundle (the old 16-arg overload is dropped — PostgREST
--     names its arguments and two overloads answering the same names is PGRST203, the trap v410
--     and v807 both name). A bundle is validated like a service (the firm's, active, schedulable);
--     a requested team member must be assigned to every member service that has assignments;
--     bundle_id is written before the v660 auto-approve runs (v660 returns null for a request with
--     no service_id, so a bundle request always waits for a human — deliberate: fail closed);
--   * internal_public_booking_availability gains p_bundle the same way (old 6-arg dropped); the
--     slot length is the bundle's summed duration plus its members' buffers; the roster is every
--     bookable team member (app.v183_bookable_staff with no service), which is a superset of what
--     the page offers, so the page never shows a person the server then refuses;
--   * the confirm path books ONE appointment with no service (a service would override duration
--     and price with its own), for the summed duration clamped to the scheduler's 15..720 window,
--     then stamps bundle_id, total_cents = the bundle price (so app.on_appointment_completed bills
--     the bundle — it prices from total_cents first), and a note beginning "Bundle: <name>" so
--     every appointment surface that prints the note says what it is.
-- Not changed, on purpose: app.on_appointment_completed still writes one sales row and no
-- sale_items for ANY appointment (service or bundle) — that is the existing completion contract,
-- and the till remains the only path that itemises. get_business_public is untouched (the v21
-- call-graph test forbids the gateway from reaching it directly; the page wrapper is the seam).
--
-- Grants restate the live proacl of every replaced function verbatim.

begin;

-- ---------------------------------------------------------------------------------------------
-- 2a. schema
-- ---------------------------------------------------------------------------------------------
alter table public.booking_requests
  add column if not exists bundle_id uuid references public.bundles(id) on delete set null;
alter table public.appointments
  add column if not exists bundle_id uuid references public.bundles(id) on delete set null;

alter table public.booking_requests drop constraint if exists booking_requests_bundle_business_fkey;
alter table public.booking_requests
  add constraint booking_requests_bundle_business_fkey
  foreign key (bundle_id, business_id) references public.bundles(id, business_id)
  on delete set null (bundle_id) not valid;
alter table public.booking_requests validate constraint booking_requests_bundle_business_fkey;

alter table public.appointments drop constraint if exists appointments_bundle_business_fkey;
alter table public.appointments
  add constraint appointments_bundle_business_fkey
  foreign key (bundle_id, business_id) references public.bundles(id, business_id)
  on delete set null (bundle_id) not valid;
alter table public.appointments validate constraint appointments_bundle_business_fkey;

alter table public.booking_requests drop constraint if exists booking_requests_service_or_bundle_v882;
alter table public.booking_requests
  add constraint booking_requests_service_or_bundle_v882
  check (service_id is null or bundle_id is null);

create index if not exists booking_requests_bundle_id_idx on public.booking_requests (bundle_id) where bundle_id is not null;
create index if not exists appointments_bundle_id_idx on public.appointments (bundle_id) where bundle_id is not null;

-- ---------------------------------------------------------------------------------------------
-- 2b. the one authority for a bundle's slot length
-- ---------------------------------------------------------------------------------------------
create or replace function app.bundle_booking_duration_v882(p_business uuid, p_bundle uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select sum(coalesce(service.duration_min, 60))::integer
    from public.bundle_items member
    join public.bundles bundle
      on bundle.id = member.bundle_id and bundle.business_id = p_business
    join public.services service
      on service.id = member.service_id and service.business_id = p_business and service.active
   where bundle.id = p_bundle
$$;
revoke all on function app.bundle_booking_duration_v882(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2c. the booking page projects bundles
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.internal_public_booking_page(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_page jsonb;
  v_business public.businesses%rowtype;
  v_staff jsonb := '[]'::jsonb;
  v_branches jsonb := '[]'::jsonb;
  v_branch_count integer;
  v_bundles jsonb := '[]'::jsonb; -- nestly_v882
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

  -- nestly_v882 (owner: "i need bundle to show for customers to select"). Bundles were a till-only
  -- concept; the booking page listed services alone. An active bundle with at least one active
  -- service member is offered with its summed duration and its own price. Product members are
  -- listed by name but add no time. Ordered like services: by name.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', bundle.id,
           'name', bundle.name,
           'price_cents', bundle.price_cents,
           'duration_min', app.bundle_booking_duration_v882(v_business.id, bundle.id),
           'service_ids', coalesce((
             select jsonb_agg(member.service_id order by member.service_id)
               from public.bundle_items member
              where member.bundle_id = bundle.id and member.service_id is not null
           ), '[]'::jsonb),
           'items', coalesce((
             select jsonb_agg(coalesce(service.name, product.name) order by member.service_id nulls last, coalesce(service.name, product.name))
               from public.bundle_items member
               left join public.services service on service.id = member.service_id and service.business_id = v_business.id
               left join public.products product on product.id = member.product_id and product.business_id = v_business.id
              where member.bundle_id = bundle.id
           ), '[]'::jsonb)
         ) order by lower(bundle.name), bundle.id), '[]'::jsonb)
    into v_bundles
    from public.bundles bundle
   where bundle.business_id = v_business.id
     and bundle.active
     and app.bundle_booking_duration_v882(v_business.id, bundle.id) is not null;

  return v_page || jsonb_build_object(
    'bundles', v_bundles,
    'booking_auto_confirm', coalesce(v_business.booking_auto_confirm, false),
    'booking_staff_choice', coalesce(v_business.booking_staff_choice, false),
    'staff', v_staff,
    'branches', v_branches
  );
exception when others then
  return null;
end;
$function$;

revoke all on function public.internal_public_booking_page(text) from public, anon, authenticated;
grant execute on function public.internal_public_booking_page(text) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2d. submit: one overload, now with p_bundle
-- ---------------------------------------------------------------------------------------------
drop function if exists public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION public.internal_public_booking_submit(p_slug text, p_name text, p_email text, p_phone text, p_service uuid, p_party integer, p_preferred timestamp with time zone, p_notes text, p_table_type uuid, p_consent boolean, p_token_hash text, p_idempotency_hash text, p_request_fingerprint text, p_authenticated_user uuid, p_staff uuid, p_branch uuid DEFAULT NULL::uuid, p_bundle uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_business_id uuid;
  v_result jsonb;
  v_request uuid;
  v_appointment uuid;
  v_auto_appointment uuid;
  v_final_status text;
  v_final_appointment uuid;
begin
  select business.id into v_business_id
    from public.businesses business
   where business.slug = p_slug
   limit 1;
  if (p_staff is not null or p_branch is not null or p_bundle is not null) and v_business_id is null then
    raise exception 'invalid request' using errcode = '22023';
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
  -- nestly_v882: a bundle is a request for its service members as one appointment. It is accepted
  -- only when it is the firm's, active, and has at least one active service member (a bundle of
  -- products alone has nothing to schedule). A service and a bundle in the same request is a
  -- malformed request, as is a table hold. The staff rule mirrors the single-service rule above:
  -- a requested team member must be assigned to EVERY member service that has assignments at all.
  if p_bundle is not null then
    if p_service is not null or p_table_type is not null then
      raise exception 'invalid request' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.bundles bundle
       where bundle.id = p_bundle
         and bundle.business_id = v_business_id
         and bundle.active
         and app.bundle_booking_duration_v882(v_business_id, bundle.id) is not null
    ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
    if p_staff is not null and exists (
      select 1 from public.bundle_items member
       where member.bundle_id = p_bundle
         and member.service_id is not null
         and exists (
           select 1 from public.staff_services mapped
            where mapped.business_id = v_business_id and mapped.service_id = member.service_id
         )
         and not exists (
           select 1 from public.staff_services mapped
            where mapped.business_id = v_business_id
              and mapped.service_id = member.service_id
              and mapped.staff_id = p_staff
         )
    ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
  end if;

  perform set_config('app.v678_autoapprove_deferred', 'on', true);
  select public.internal_public_booking_submit(
    p_slug, p_name, p_email, p_phone, p_service, p_party, p_preferred,
    p_notes, p_table_type, p_consent, p_token_hash, p_idempotency_hash,
    p_request_fingerprint, p_authenticated_user
  ) into v_result;
  perform set_config('app.v678_autoapprove_deferred', 'off', true);
  if v_result is null
     or coalesce((v_result->>'conflict')::boolean, false)
     or coalesce((v_result->>'replayed')::boolean, false) then
    return v_result;
  end if;
  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;
  if v_request is not null and (p_staff is not null or p_branch is not null or p_bundle is not null) then
    update public.booking_requests
       set staff_id = case when p_staff is not null then p_staff else staff_id end,
           branch_id = case when p_branch is not null then p_branch else branch_id end,
           bundle_id = case when p_bundle is not null then p_bundle else bundle_id end
     where id = v_request
       and business_id = v_business_id;
  end if;
  if v_appointment is not null and (p_staff is not null or p_branch is not null) then
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
  if v_request is not null then
    begin
      v_auto_appointment := app.v660_autoapprove_booking_request(v_request);
    exception when others then
      v_auto_appointment := null;
    end;
    select request_row.status, request_row.appointment_id
      into v_final_status, v_final_appointment
      from public.booking_requests request_row
     where request_row.id = v_request;
    if v_final_status = 'confirmed' and v_final_appointment is not null
       and v_final_appointment is distinct from v_appointment then
      v_result := v_result || jsonb_build_object(
        'status', 'confirmed',
        'appointment_id', v_final_appointment,
        'auto_approved', true);
      update app.booking_management_tokens token
         set initial_response = v_result - 'replayed'
       where token.booking_request_id = v_request
         and token.business_id = v_business_id;
    end if;
  end if;
  return v_result;
end;
$function$;

revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2e. availability: one overload, now with p_bundle
-- ---------------------------------------------------------------------------------------------
drop function if exists public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid);
CREATE OR REPLACE FUNCTION public.internal_public_booking_availability(p_slug text, p_service uuid, p_staff uuid, p_from date, p_days integer, p_branch uuid DEFAULT NULL::uuid, p_bundle uuid DEFAULT NULL::uuid)
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
  v_buffer_before integer := 0;
  v_break_branch uuid;
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

  -- nestly_v882: a bundle is validated like a service; its slot length is the sum of its service
  -- members (product members schedule nothing). A bundle AND a service is a malformed request.
  if p_bundle is not null and (
    p_service is not null
    or not exists (
      select 1 from public.bundles bundle
       where bundle.id = p_bundle
         and bundle.business_id = v_business.id
         and bundle.active
         and app.bundle_booking_duration_v882(v_business.id, bundle.id) is not null
    )
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
  if p_bundle is not null then
    select app.bundle_booking_duration_v882(v_business.id, p_bundle)
         + coalesce((
             select sum(coalesce(service.buffer_before_min, 0) + coalesce(service.buffer_after_min, 0))
               from public.bundle_items member
               join public.services service
                 on service.id = member.service_id and service.business_id = v_business.id
              where member.bundle_id = p_bundle
           ), 0)
      into v_duration;
  end if;
  v_duration := greatest(coalesce(v_duration, 60), 5);
  select coalesce(service.buffer_before_min, 0)
    into v_buffer_before
    from public.services service
   where service.id = p_service
     and service.business_id = v_business.id;
  v_buffer_before := greatest(coalesce(v_buffer_before, 0), 0);
  v_break_branch := coalesce(p_branch, app.default_branch(v_business.id));

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
           coalesce(branch.branch_id, v_break_branch) as branch_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar
      cross join app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) member
      left join public.staff_hours own
        on own.business_id = v_business.id
       and own.staff_id = member.staff_id
       and own.weekday = extract(dow from calendar.day)::smallint
      left join lateral (
        select hours.opens_at, hours.closes_at, branch_row.id as branch_id
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
      ) branch on true
     where coalesce(own.starts_at, branch.opens_at) is not null
       and coalesce(own.ends_at, branch.closes_at) is not null
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
           windows.branch_id,
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
          left join public.services booked_service
            on booked_service.id = booked.service_id
           and booked_service.business_id = booked.business_id
          where booked.business_id = v_business.id
            and booked.staff_id = slots.staff_id
            and booked.status not in ('cancelled', 'no_show', 'declined')
            and tstzrange(
                  booked.starts_at
                    - make_interval(mins => coalesce(booked_service.buffer_before_min, 0)),
                  coalesce(booked.ends_at, booked.starts_at + interval '1 hour')
                    + make_interval(mins => coalesce(booked_service.buffer_after_min, 0)), '[)')
                && tstzrange(slots.slot_at - make_interval(mins => v_buffer_before),
                             slots.slot_at - make_interval(mins => v_buffer_before)
                               + make_interval(mins => v_duration), '[)')
       )
       and not exists (
         select 1 from public.staff_blocked_times blocked
          where blocked.business_id = v_business.id
            and blocked.staff_id = slots.staff_id
            and tstzrange(blocked.starts_at, blocked.ends_at, '[)')
                && tstzrange(slots.slot_at - make_interval(mins => v_buffer_before),
                             slots.slot_at - make_interval(mins => v_buffer_before)
                               + make_interval(mins => v_duration), '[)')
       )
       and not exists (
         select 1 from public.branch_breaks pause
          where pause.business_id = v_business.id
            and pause.branch_id = slots.branch_id
            and pause.weekday = extract(dow from
                  (slots.slot_at - make_interval(mins => v_buffer_before))
                    at time zone 'Asia/Singapore')::smallint
            and pause.starts_at < ((slots.slot_at - make_interval(mins => v_buffer_before)
                  + make_interval(mins => v_duration)) at time zone 'Asia/Singapore')::time
            and pause.ends_at > ((slots.slot_at - make_interval(mins => v_buffer_before))
                  at time zone 'Asia/Singapore')::time
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

revoke all on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid, uuid) from public;
grant execute on function public.internal_public_booking_availability(text, uuid, uuid, date, integer, uuid, uuid)
  to service_role, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1b + 2f. the confirm path: past_start is an outcome; a bundle books one appointment
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_decide_booking_request_v73_v94_base(p_business uuid, p_request uuid, p_decision text, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
  v_bundle public.bundles%rowtype;      -- nestly_v882
  v_service_arg uuid;                  -- nestly_v882
  v_note text;                         -- nestly_v882
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

  -- nestly_v882: a request whose preferred time has already passed cannot be confirmed AS FILED —
  -- book_appointment_smart_v47 refuses any start older than five minutes ("appointment start must
  -- be in the future"), and until now that 22023 escaped this function raw (the block below caught
  -- only P0731/exclusion), so the Bookings page showed staff a bare database sentence with no next
  -- step (AhXiang, 2026-09-08: two New rows preferred 28 Aug / 3 Sep). It is a structured outcome
  -- now, mirroring the scheduler's own grace so the two never disagree at the boundary. The rescue
  -- is staff_reschedule_and_confirm_booking_request_v329, which moves preferred_at first.
  if v_request.preferred_at is not null
     and v_request.preferred_at < clock_timestamp() - interval '5 minutes' then
    return app.booking_decision_result_v73(
      p_business, p_request, p_decision, 'past_start', false
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

    -- nestly_v882: a bundle request books ONE appointment for the sum of its service members'
    -- durations (the scheduler's 15..720 window still applies), priced at the bundle price so the
    -- completion sale bills the bundle, and named in the note so every appointment surface that
    -- prints the note says which bundle it is. The scheduler is given no service, because a
    -- service would override the duration and price with its own.
    v_service_arg := v_request.service_id;
    v_note := v_request.notes;
    if v_request.bundle_id is not null then
      select bundle.* into v_bundle
        from public.bundles bundle
       where bundle.id = v_request.bundle_id
         and bundle.business_id = p_business
         and bundle.active;
      if not found then
        raise exception 'the requested bundle is no longer available' using errcode = '22023';
      end if;
      v_duration := least(greatest(coalesce(app.bundle_booking_duration_v882(p_business, v_bundle.id), 60), 15), 720);
      v_service_arg := null;
      v_note := concat_ws(' — ', 'Bundle: ' || v_bundle.name, nullif(btrim(coalesce(v_request.notes, '')), ''));
    else
      select greatest(service.duration_min, 15) into v_duration
        from public.services service
       where service.id = v_request.service_id
         and service.business_id = p_business;
      v_duration := coalesce(v_duration, 60);
    end if;

    v_booking := public.book_appointment_smart_v47(
      p_business, v_client, v_branch, v_service_arg,
      coalesce(v_request.preferred_at, clock_timestamp() + interval '1 day'),
      v_duration, v_staff,
      case when v_staff is not null then 'manual' else 'round_robin' end,
      v_note,
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
           table_type_id = v_request.table_type_id,
           bundle_id = v_request.bundle_id,
           total_cents = case when v_bundle.id is not null then v_bundle.price_cents else total_cents end
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
    when sqlstate '22023' then
      -- nestly_v882: only the scheduler's past-start refusal is translated; every other 22023 is
      -- a real input fault and keeps raising.
      if sqlerrm like '%must be in the future%' then
        return app.booking_decision_result_v73(
          p_business, p_request, p_decision, 'past_start', false
        );
      end if;
      raise;
  end;

  return app.booking_decision_result_v73(
    p_business, p_request, p_decision, 'applied', false
  );
end
$function$;

revoke all on function public.staff_decide_booking_request_v73_v94_base(uuid, uuid, text, uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 1a. the per-minute sweep ages a request out one day after its preferred time
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.expire_stale_bookings()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare r record; n int := 0;
begin
  for r in
    update public.booking_requests
       set status = 'expired'
     where status in ('new','pending')
       and expires_at is not null
       and expires_at < now()
    returning id, business_id, name, table_type_id
  loop
    n := n + 1;
    insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
    values (r.business_id, 'booking_expired', 'Booking hold expired',
            coalesce(r.name,'A guest') || ' — held table released.',
            'booking_requests', r.id);
    if exists (
      select 1 from public.waitlist w
       where w.business_id = r.business_id and w.status = 'waiting'
         and (r.table_type_id is null or w.table_type_id is null or w.table_type_id = r.table_type_id)
    ) then
      insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
      values (r.business_id, 'waitlist_ready', 'A table opened up',
              'A held table was released — contact your waitlist.',
              'booking_requests', r.id);
    end if;
  end loop;
  -- nestly_v882: service requests never set expires_at (only table holds do), so a New request
  -- whose preferred time passed stayed New for ever — still counted in the Appointment badge,
  -- still offering a Confirm that could only fail. A request is aged out one day after its
  -- preferred time: that day is the window in which staff can still rescue it with Move & confirm
  -- (staff_reschedule_and_confirm_booking_request_v329), which needs the row to be pending.
  for r in
    update public.booking_requests
       set status = 'expired'
     where status in ('new','pending')
       and preferred_at is not null
       and preferred_at < now() - interval '1 day'
    returning id, business_id, name, preferred_at
  loop
    n := n + 1;
    insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
    values (r.business_id, 'booking_expired', 'Booking request expired',
            coalesce(r.name,'A guest') || ' — the requested time (' ||
            to_char(r.preferred_at at time zone 'Asia/Singapore', 'DD Mon HH24:MI') ||
            ') passed without a decision.',
            'booking_requests', r.id);
  end loop;
  return n;
end $function$;

revoke all on function app.expire_stale_bookings() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- proof: exactly one overload of each public booking RPC answers the gateway's named call
-- ---------------------------------------------------------------------------------------------
do $verify$
declare n integer;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'internal_public_booking_submit'
     and pg_get_function_identity_arguments(p.oid) like '%p_staff uuid, p_branch uuid%';
  if n <> 1 then raise exception 'nestly_v882: expected one 17-arg internal_public_booking_submit, found %', n; end if;
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'internal_public_booking_availability';
  if n <> 1 then raise exception 'nestly_v882: expected one internal_public_booking_availability, found %', n; end if;
  if position('past_start' in pg_get_functiondef('public.staff_decide_booking_request_v73_v94_base(uuid,uuid,text,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v882: past_start outcome missing from the confirm path';
  end if;
  if position('preferred_at < now() - interval ''1 day''' in pg_get_functiondef('app.expire_stale_bookings()'::regprocedure)) = 0 then
    raise exception 'nestly_v882: preferred_at sweep missing from app.expire_stale_bookings';
  end if;
end $verify$;

commit;
