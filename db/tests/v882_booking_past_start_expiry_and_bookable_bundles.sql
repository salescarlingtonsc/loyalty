-- nestly_v882 rolled-back verification — past-start outcome, preferred_at expiry, bookable bundles.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Fixture shape copied from db/tests/v329 (owner + two bookable
-- team members + one branch with hours), plus a bundle of two services (30 + 45 min, SGD 158).
--
--   1. the public page projects the bundle with its summed duration and service ids;
--   2. a public submit naming the bundle produces a request with bundle_id and no service_id;
--   3. availability asked for the bundle sizes slots at the summed duration;
--   4. Confirm books ONE appointment: 75 minutes, priced at the bundle, note "Bundle: …", no
--      service_id, bundle_id stamped — through the public wrapper the real button uses;
--   5. a bundle alongside a service, and an inactive bundle, are refused (22023);
--   6. a request whose preferred time has passed confirms to the structured outcome 'past_start'
--      and stays pending (rescuable), instead of raising the scheduler's raw 22023;
--   7. app.expire_stale_bookings ages a service request out one day after its preferred time and
--      leaves a notification, while a request inside that day is left alone.

\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.as_v882_user(
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
grant execute on function pg_temp.as_v882_user(uuid, text) to public;

create or replace function pg_temp.approve_v882_workspace(p_business uuid)
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
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_staff_a uuid := gen_random_uuid();
  v_staff_b uuid := gen_random_uuid();
  v_service_1 uuid := gen_random_uuid();
  v_service_2 uuid := gen_random_uuid();
  v_bundle uuid := gen_random_uuid();
  v_bundle_off uuid := gen_random_uuid();
  v_slug text := 'v882-' || v_business;
  v_page jsonb;
  v_bundle_row jsonb;
  v_result jsonb;
  v_avail jsonb;
  v_decision jsonb;
  v_request uuid;
  v_request_past uuid;
  v_request_fresh uuid;
  v_appointment record;
  v_expired integer;
  v_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v882-owner-' || v_owner || '@example.test', '', now(), now(), now()
  );

  insert into public.businesses(
    id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm,
    enabled_modules
  ) values (
    v_business, 'V882 Bundles', v_slug, 'SGD', true, true, false,
    array['dashboard','clients','sales','loyalty','retention','bookings','appointments']
  );
  perform pg_temp.approve_v882_workspace(v_business);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V882 Branch', 'Asia/Singapore', true, true);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, weekday, time '00:00', time '23:59'
    from generate_series(0, 6) weekday;

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V882 Owner', true, false),
    (v_staff_a, v_business, null, 'staff', 'V882 A', true, true),
    (v_staff_b, v_business, null, 'staff', 'V882 B', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_a, v_branch), (v_business, v_staff_b, v_branch);
  update public.staff_hours
     set starts_at = time '00:00', ends_at = time '23:59'
   where staff_id in (v_staff_a, v_staff_b);

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service_1, v_business, 'V882 Massage', 8800, 30, true, true),
         (v_service_2, v_business, 'V882 Facial', 9800, 45, true, true);

  insert into public.bundles(id, business_id, name, price_cents, active)
  values (v_bundle, v_business, 'V882 Ritual', 15800, true),
         (v_bundle_off, v_business, 'V882 Retired', 9900, false);
  insert into public.bundle_items(bundle_id, service_id)
  values (v_bundle, v_service_1), (v_bundle, v_service_2), (v_bundle_off, v_service_1);

  -- 1. the page projects the bundle with its summed duration.
  v_page := public.internal_public_booking_page(v_slug);
  assert v_page is not null, 'the booking page must render';
  select item into v_bundle_row
    from jsonb_array_elements(coalesce(v_page->'bundles', '[]'::jsonb)) item
   where (item->>'id')::uuid = v_bundle;
  assert v_bundle_row is not null, 'the active bundle must be listed on the booking page';
  assert (v_bundle_row->>'duration_min')::integer = 75, 'bundle duration must be the sum of its services (30 + 45)';
  assert (v_bundle_row->>'price_cents')::integer = 15800, 'bundle price must be its own price';
  assert jsonb_array_length(v_bundle_row->'service_ids') = 2, 'bundle must carry its service ids';
  assert not exists (
    select 1 from jsonb_array_elements(v_page->'bundles') item where (item->>'id')::uuid = v_bundle_off
  ), 'an inactive bundle must not be listed';
  assert app.bundle_booking_duration_v882(v_business, v_bundle) = 75, 'the duration authority agrees';

  -- 2. a public submit naming the bundle.
  v_result := public.internal_public_booking_submit(
    v_slug, 'V882 Customer', 'v882@example.com', null, null, 1,
    v_preferred, null, null, false,
    repeat('a', 64), repeat('b', 64), repeat('c', 64), null, v_staff_a, null, v_bundle);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a bundle submit must produce a request';
  assert (select bundle_id from public.booking_requests where id = v_request) = v_bundle,
    'the request must carry the bundle';
  assert (select service_id from public.booking_requests where id = v_request) is null,
    'a bundle request names no service';

  -- 3. availability asked for the bundle sizes slots at the summed duration.
  v_avail := public.internal_public_booking_availability(v_slug, null, null, current_date + 2, 1, null, v_bundle);
  assert v_avail is not null, 'availability for a bundle must answer';
  assert (v_avail->>'duration_minutes')::integer = 75, 'slot length must be the bundle''s summed duration';

  -- 5a. a bundle alongside a service is refused.
  begin
    perform public.internal_public_booking_submit(
      v_slug, 'V882 Customer', 'v882@example.com', null, v_service_1, 1,
      v_preferred + interval '2 hours', null, null, false,
      repeat('d', 64), repeat('e', 64), repeat('f', 64), null, null, null, v_bundle);
    raise exception 'expected a bundle alongside a service to be refused';
  exception when sqlstate '22023' then null;
  end;
  -- 5b. an inactive bundle is refused.
  begin
    perform public.internal_public_booking_submit(
      v_slug, 'V882 Customer', 'v882@example.com', null, null, 1,
      v_preferred + interval '2 hours', null, null, false,
      repeat('1', 64), repeat('2', 64), repeat('3', 64), null, null, null, v_bundle_off);
    raise exception 'expected an inactive bundle to be refused';
  exception when sqlstate '22023' then null;
  end;

  -- 4. Confirm through the public wrapper the real button uses.
  perform pg_temp.as_v882_user(v_owner);
  v_decision := public.staff_decide_booking_request_v73(v_business, v_request, 'confirm', null);
  assert v_decision->>'outcome' = 'applied', 'confirming a bundle request must apply: ' || v_decision::text;
  reset role;
  select appointment.* into v_appointment
    from public.appointments appointment
   where appointment.id = (v_decision->>'appointment_id')::uuid
     and appointment.business_id = v_business;
  assert v_appointment.bundle_id = v_bundle, 'the appointment must carry the bundle';
  assert v_appointment.service_id is null, 'a bundle appointment names no single service';
  assert v_appointment.ends_at - v_appointment.starts_at = interval '75 minutes',
    'the appointment must span the summed duration, got ' || (v_appointment.ends_at - v_appointment.starts_at)::text;
  assert v_appointment.total_cents = 15800, 'the appointment must be priced at the bundle';
  assert v_appointment.note like 'Bundle: V882 Ritual%', 'the note must name the bundle, got ' || coalesce(v_appointment.note, '<null>');
  assert v_appointment.staff_id = v_staff_a, 'the customer''s team-member choice must be honoured';

  -- 6. a request whose preferred time has passed: structured outcome, still rescuable.
  v_result := public.internal_public_booking_submit(
    v_slug, 'V882 Late', 'late@example.com', null, v_service_1, 1,
    v_preferred + interval '1 day', null, null, false,
    repeat('4', 64), repeat('5', 64), repeat('6', 64), null, null, null, null);
  v_request_past := nullif(v_result->>'request_id', '')::uuid;
  assert v_request_past is not null, 'the second request must be created';
  update public.booking_requests set preferred_at = clock_timestamp() - interval '2 hours' where id = v_request_past;
  perform pg_temp.as_v882_user(v_owner);
  v_decision := public.staff_decide_booking_request_v73(v_business, v_request_past, 'confirm', null);
  reset role;
  assert v_decision->>'outcome' = 'past_start', 'a passed preferred time must be the past_start outcome, got ' || v_decision::text;
  assert (select status from public.booking_requests where id = v_request_past) in ('new', 'pending'),
    'a past_start request must stay pending so Move & confirm can still rescue it';

  -- 7. the sweep ages it out one day after its preferred time, and not before.
  v_expired := app.expire_stale_bookings();
  assert (select status from public.booking_requests where id = v_request_past) in ('new', 'pending'),
    'two hours past is inside the rescue window — must not expire yet';
  update public.booking_requests set preferred_at = clock_timestamp() - interval '2 days' where id = v_request_past;
  v_expired := app.expire_stale_bookings();
  assert (select status from public.booking_requests where id = v_request_past) = 'expired',
    'two days past must expire';
  assert exists (
    select 1 from public.notifications n
     where n.business_id = v_business and n.kind = 'booking_expired' and n.ref_id = v_request_past
  ), 'expiry must leave a notification';

  raise notice 'v882 verification passed';
end $test$;

rollback;
