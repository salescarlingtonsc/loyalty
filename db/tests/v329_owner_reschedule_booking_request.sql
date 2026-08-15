-- v329 rolled-back verification — owner-side booking-request reschedule.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Assertions cover:
--   1. rescheduling a pending request to a new time and a different team member confirms it
--      onto that exact time and team member, not the customer's original request;
--   2. a non-pending (already confirmed) request is refused;
--   3. a past preferred time is refused;
--   4. an actor with no 'bookings' write access is refused (42501).
--
-- Reschedules through public.staff_reschedule_and_confirm_booking_request_v329, which itself
-- calls the public wrapper staff_decide_booking_request_v73 (granted to authenticated) — never
-- the v94-renamed base function directly, which is revoked from every role and would pass under
-- a permission model the real Confirm button never uses (the same lesson v328's test fix
-- applied: db/tests/v328_staff_choice_manual_confirm.sql).

begin;

create or replace function pg_temp.as_v329_user(
  p_uid uuid, p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config(
    'request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true
  );
end
$$;
grant execute on function pg_temp.as_v329_user(uuid, text) to public;

create or replace function pg_temp.approve_v329_workspace(p_business uuid)
returns void language sql as $$
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),
         decision_reason='approved synthetic rollback fixture',
         updated_at=statement_timestamp()
   where business_id=p_business and approval_status='pending'
$$;

do $test$
declare
  v_owner uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_staff_original uuid := gen_random_uuid();
  v_staff_moved_to uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_slug text := 'v329-' || v_business;
  v_result jsonb;
  v_decision jsonb;
  v_request uuid;
  v_appointment record;
  v_original_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
  v_moved_preferred timestamptz := ((current_date + 3) + time '15:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v329-owner-' || v_owner || '@example.test', '', now(), now(), now()
  ), (
    '00000000-0000-0000-0000-000000000000', v_outsider, 'authenticated',
    'authenticated', 'v329-outsider-' || v_outsider || '@example.test', '', now(), now(), now()
  );

  insert into public.businesses(
    id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm,
    enabled_modules
  ) values (
    v_business, 'V329 Reschedule', v_slug, 'SGD', true, true, false,
    array['dashboard','clients','sales','loyalty','retention','bookings','appointments']
  );
  perform pg_temp.approve_v329_workspace(v_business);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V329 Branch', 'Asia/Singapore', true, true);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, weekday, time '00:00', time '23:59'
    from generate_series(0, 6) weekday;

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V329 Owner', true, false),
    (v_staff_original, v_business, null, 'staff', 'V329 Original', true, true),
    (v_staff_moved_to, v_business, null, 'staff', 'V329 Moved To', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_original, v_branch), (v_business, v_staff_moved_to, v_branch);
  -- Staff creation already seeds a default staff_hours row per weekday (trigger); widen those
  -- rather than inserting fresh ones, which would collide on the (staff_id, weekday) unique key.
  update public.staff_hours
     set starts_at = time '00:00', ends_at = time '23:59'
   where staff_id in (v_staff_original, v_staff_moved_to);

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service, v_business, 'V329 Service', 5000, 30, true, true);

  v_result := public.internal_public_booking_submit(
    v_slug, 'V329 Customer', 'customer@example.com', null, v_service, 1,
    v_original_preferred, null, null, false,
    repeat('1', 64), repeat('2', 64), repeat('3', 64), null, v_staff_original);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a non-auto-confirm business must produce a pending request';

  -- 4. an actor with no staff row at all (no bookings access) must be refused.
  perform pg_temp.as_v329_user(v_outsider);
  begin
    perform public.staff_reschedule_and_confirm_booking_request_v329(
      v_business, v_request, v_moved_preferred, v_staff_moved_to);
    raise exception 'expected an actor with no bookings access to be refused';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- 3. a past preferred time must be refused.
  perform pg_temp.as_v329_user(v_owner);
  begin
    perform public.staff_reschedule_and_confirm_booking_request_v329(
      v_business, v_request, clock_timestamp() - interval '1 day', v_staff_moved_to);
    raise exception 'expected a past preferred time to be refused';
  exception when sqlstate '22023' then null;
  end;

  -- 1. reschedule to a new time and a different team member, then confirm.
  v_decision := public.staff_reschedule_and_confirm_booking_request_v329(
    v_business, v_request, v_moved_preferred, v_staff_moved_to);
  assert v_decision->>'outcome' = 'applied', 'the reschedule-and-confirm must succeed';
  select appointment.starts_at, appointment.staff_id into v_appointment
    from public.appointments appointment
   where appointment.id = (v_decision->>'appointment_id')::uuid
     and appointment.business_id = v_business;
  assert v_appointment.starts_at = v_moved_preferred,
    'the confirmed appointment must land at the NEW time, not the customer''s original request';
  assert v_appointment.staff_id = v_staff_moved_to,
    'the confirmed appointment must be assigned to the NEW team member';
  assert (select preferred_at from public.booking_requests where id = v_request) = v_moved_preferred,
    'the request row itself must record the new preferred time';

  -- 2. a non-pending (already confirmed) request must be refused.
  begin
    perform public.staff_reschedule_and_confirm_booking_request_v329(
      v_business, v_request, v_moved_preferred + interval '1 hour', v_staff_original);
    raise exception 'expected an already-confirmed request to be refused';
  exception when sqlstate '22023' then null;
  end;
  reset role;

  raise notice 'v329 verification passed';
end $test$;

rollback;
