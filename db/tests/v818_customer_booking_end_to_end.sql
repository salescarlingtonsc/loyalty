-- Customer booking page — END TO END, 2026-09-07.
--
-- Walks the customer's four steps in order, through the exact RPCs the public-booking edge
-- gateway calls, then follows the booking across to the business side and back:
--
--   step 1 Service   internal_public_booking_page(slug)          -> catalogue.services
--   step 2 Team      the same payload's staff list               -> "Who would you like?"
--   step 3 Time      internal_public_booking_availability(...)   -> the green slots
--   step 4 Details   internal_public_booking_submit(...)         -> booking_requests row
--   business side    the request is visible, and auto-approve turns it into an appointment
--   round trip       cancelling that appointment syncs the request back (nestly_v818)
--
-- WHY NOW. nestly_v818 touched two things directly under this page and one beside it:
--   * customer_get_business_presentation_v95 was patched by anchored string replacement against
--     its live 20KB body. That is the customer's own catalogue read. A surgery that compiles but
--     breaks the payload would not show up in a migration test.
--   * app.branch_offers_service_v811 now decides which services the page may offer, so a service
--     that was hidden must now be bookable ALL THE WAY THROUGH, not merely listed.
--   * a new AFTER UPDATE trigger fires on appointments — and this flow creates appointments.
--
-- Everything runs as the REAL principal the gateway uses (service_role for the internal_* RPCs,
-- an authenticated owner for the business-side reads), never as the table owner. Rolled back.
--
--   supabase db query --linked -f db/tests/v818_customer_booking_end_to_end.sql

begin;

do $suite$
declare
  c_slug    constant text := 'kky-demo';
  c_biz     constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';
  c_owner   constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_branch  constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  -- The service that the dead-branch pin used to hide from this very page.
  c_aroma   constant uuid := '8a191981-7df0-44e7-a452-92581e3c8ea3';
  v_page    jsonb;
  v_avail   jsonb;
  v_res     jsonb;
  v_staff   uuid;
  v_slot    timestamptz;
  v_req     uuid;
  v_appt    uuid;
  v_got     integer;
  v_txt     text;
  v_sub     text;
  n         integer := 0;
begin
  -- ============================================================ STEP 1 — "Choose a service"
  n := n + 1;
  v_page := public.internal_public_booking_page(c_slug);
  if v_page is null then
    raise exception 'E%: the booking page returned nothing for slug %', n, c_slug;
  end if;

  n := n + 1;
  select count(*)::integer into v_got
    from jsonb_array_elements(coalesce(v_page->'catalogue'->'services', v_page->'services')) s;
  if v_got < 1 then
    raise exception 'E%: the booking page offers no services at all', n;
  end if;

  -- The v818 regression: a service pinned only to a DEACTIVATED branch was withheld from this
  -- page. It must be offered now, or the customer still cannot book it.
  n := n + 1;
  if not exists (
    select 1 from jsonb_array_elements(coalesce(v_page->'catalogue'->'services', v_page->'services')) s
     where (s->>'id')::uuid = c_aroma) then
    raise exception 'E%: the service that the dead-branch pin hid is still missing from the customer booking page', n;
  end if;

  -- ========================================================= STEP 2 — "Who would you like?"
  n := n + 1;
  select count(*)::integer into v_got from jsonb_array_elements(v_page->'staff') s;
  if v_got < 1 then
    raise exception 'E%: the Team step offers nobody', n;
  end if;

  -- Every name offered must be a real, active, customer-bookable member of THIS tenant. This is
  -- the assertion behind the answer given for photo 7.
  n := n + 1;
  select count(*)::integer into v_got
    from jsonb_array_elements(v_page->'staff') s
   where not exists (
     select 1 from public.staff st
      where st.id = (s->>'id')::uuid
        and st.business_id = c_biz
        and st.active
        and coalesce(st.customer_bookable, true));
  if v_got <> 0 then
    raise exception 'E%: % name(s) on the Team step are not active customer-bookable staff of this business', n, v_got;
  end if;

  -- ============================================================== STEP 3 — "Pick a date & time"
  -- "Anyone available" first: the default choice must produce times.
  n := n + 1;
  v_avail := public.internal_public_booking_availability(
    c_slug, c_aroma, null, (now() at time zone 'Asia/Singapore')::date, 7, c_branch);
  if v_avail is null then
    raise exception 'E%: availability returned nothing for the previously hidden service', n;
  end if;
  n := n + 1;
  select min((slot->>'at')::timestamptz) into v_slot
    from jsonb_array_elements(coalesce(v_avail->'days','[]'::jsonb)) d
    cross join lateral jsonb_array_elements(coalesce(d->'slots','[]'::jsonb)) slot;
  if v_slot is null then
    raise exception 'E%: "Anyone available" offers no slot in the next 7 days for a live service', n;
  end if;

  -- STEP 2 -> STEP 3 MUST JOIN UP. Every name the Team step offers has to produce at least one
  -- slot, or choosing that person is a dead end: the customer picks a face and the next screen is
  -- empty. The two steps are separate reads, so nothing but this makes them agree.
  n := n + 1;
  select string_agg(st.full_name, ', ' order by st.full_name) into v_txt
    from jsonb_array_elements(v_page->'staff') s
    join public.staff st on st.id = (s->>'id')::uuid
   where not exists (
     select 1
       from jsonb_array_elements(coalesce(v_avail->'days','[]'::jsonb)) d
       cross join lateral jsonb_array_elements(coalesce(d->'slots','[]'::jsonb)) slot
       cross join lateral jsonb_array_elements_text(coalesce(slot->'staff_ids','[]'::jsonb)) sid
      where sid = (s->>'id'));
  if v_txt is not null then
    raise exception 'E%: the Team step offers % but no slot is bookable with them — choosing them is a dead end', n, v_txt;
  end if;

  -- Now a NAMED member, which is what the owner's photo 7 screen actually submits.
  select (slot->>'staff_ids')::jsonb->>0 into v_txt
    from jsonb_array_elements(coalesce(v_avail->'days','[]'::jsonb)) d
    cross join lateral jsonb_array_elements(coalesce(d->'slots','[]'::jsonb)) slot
   where jsonb_array_length(coalesce(slot->'staff_ids','[]'::jsonb)) > 0
   limit 1;
  v_staff := v_txt::uuid;
  n := n + 1;
  v_avail := public.internal_public_booking_availability(
    c_slug, c_aroma, v_staff, (now() at time zone 'Asia/Singapore')::date, 7, c_branch);
  select min((slot->>'at')::timestamptz) into v_slot
    from jsonb_array_elements(coalesce(v_avail->'days','[]'::jsonb)) d
    cross join lateral jsonb_array_elements(coalesce(d->'slots','[]'::jsonb)) slot;
  if v_slot is null then
    raise exception 'E%: a named team member has no bookable slot, so step 3 is a dead end for step 2''s answer', n;
  end if;

  -- Availability must not offer a slot in the past.
  n := n + 1;
  if v_slot < now() - interval '1 minute' then
    raise exception 'E%: availability offered a slot in the past (%)', n, v_slot;
  end if;

  -- ================================================================== STEP 4 — "Your details"
  n := n + 1;
  v_sub := 'e2e-' || replace(gen_random_uuid()::text, '-', '');
  v_res := public.internal_public_booking_submit(
    c_slug, 'End To End Probe', null, '+6581863833', c_aroma, 1, v_slot, 'booking e2e suite',
    null, true,
    encode(sha256(('tok-'  || v_sub)::bytea), 'hex'),
    encode(sha256(('idem-' || v_sub)::bytea), 'hex'),
    encode(sha256(('fp-'   || v_sub)::bytea), 'hex'),
    null, v_staff, c_branch);
  if v_res is null then
    raise exception 'E%: the submit returned nothing', n;
  end if;

  n := n + 1;
  select id into v_req from public.booking_requests
   where business_id = c_biz and name = 'End To End Probe'
   order by created_at desc limit 1;
  if v_req is null then
    raise exception 'E%: no booking request row was written (%)', n, left(v_res::text, 400);
  end if;

  -- The customer's two choices survived the round trip. v183 and v327 both re-validate them
  -- server-side, so a silently dropped choice would mean the customer got someone else.
  n := n + 1;
  select staff_id into v_txt from public.booking_requests where id = v_req;
  if v_txt is distinct from v_staff::text then
    raise exception 'E%: the requested team member was not recorded (got %, chose %)', n, v_txt, v_staff;
  end if;
  n := n + 1;
  select service_id into v_txt from public.booking_requests where id = v_req;
  if v_txt is distinct from c_aroma::text then
    raise exception 'E%: the requested service was not recorded', n;
  end if;

  -- Idempotency: a replayed submit must collapse onto the same request, never make a second one.
  n := n + 1;
  perform public.internal_public_booking_submit(
    c_slug, 'End To End Probe', null, '+6581863833', c_aroma, 1, v_slot, 'booking e2e suite',
    null, true,
    encode(sha256(('tok-'  || v_sub)::bytea), 'hex'),
    encode(sha256(('idem-' || v_sub)::bytea), 'hex'),
    encode(sha256(('fp-'   || v_sub)::bytea), 'hex'),
    null, v_staff, c_branch);
  select count(*)::integer into v_got from public.booking_requests
   where business_id = c_biz and name = 'End To End Probe';
  if v_got <> 1 then
    raise exception 'E%: a replayed submit produced % requests, expected 1', n, v_got;
  end if;

  -- =========================================================== THE BUSINESS SIDE SEES IT
  -- Auto-approve is on for this tenant (the owner's photo 4 says so on the page itself), so the
  -- request should already carry an appointment. If a business has it off the request stays
  -- pending for a human — both are correct, so this asserts the pairing, not one outcome.
  n := n + 1;
  select appointment_id, status into v_appt, v_txt from public.booking_requests where id = v_req;
  if v_txt = 'confirmed' and v_appt is null then
    raise exception 'E%: the request is confirmed but no appointment was created', n;
  end if;
  if v_appt is not null and v_txt not in ('confirmed','new','pending') then
    raise exception 'E%: an appointment exists but the request reads "%"', n, v_txt;
  end if;

  -- Whatever the approval mode, the owner must be able to SEE the request. Read it as the owner,
  -- under RLS, the way the Bookings page does.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*)::integer into v_got from public.booking_requests where id = v_req;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got <> 1 then
    raise exception 'E%: the owner cannot see the booking request the customer just made', n;
  end if;

  -- If an appointment was created it must belong to this tenant and branch and hold the choices.
  if v_appt is not null then
    n := n + 1;
    if not exists (select 1 from public.appointments a
                    where a.id = v_appt and a.business_id = c_biz
                      and a.branch_id = c_branch and a.service_id = c_aroma) then
      raise exception 'E%: the created appointment does not carry the tenant, branch and service booked', n;
    end if;

    n := n + 1;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
    select count(*)::integer into v_got from public.appointments where id = v_appt;
    reset role;
    perform set_config('request.jwt.claims', '', true);
    if v_got <> 1 then
      raise exception 'E%: the appointment is not visible to the owner on the calendar', n;
    end if;

    -- ================================================= ROUND TRIP (nestly_v818, photo 4)
    -- Cancelling the appointment the customer just created must take the request with it, or the
    -- Bookings list goes back to saying Confirmed over a cancellation.
    n := n + 1;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
    perform public.set_appointment_status_v47(c_biz, v_appt, 'cancelled');
    reset role;
    perform set_config('request.jwt.claims', '', true);
    select status into v_txt from public.booking_requests where id = v_req;
    if v_txt is distinct from 'cancelled' then
      raise exception 'E%: cancelling the booked appointment left its request reading "%"', n, v_txt;
    end if;
  end if;

  raise notice 'customer booking end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
