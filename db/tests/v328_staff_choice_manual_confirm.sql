-- v328 rolled-back verification — customer staff choice honoured on manual booking confirmation.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Assertions cover:
--   1. a manual (non-auto-confirm) request carrying the customer's staff choice is confirmed
--      onto that exact staff member, not whichever round-robin would otherwise pick;
--   2. if that staff member is deactivated before the manual confirm runs, the confirm still
--      succeeds (falls back to round-robin) instead of failing the whole decision.

begin;

create or replace function pg_temp.as_v328_user(
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
grant execute on function pg_temp.as_v328_user(uuid, text) to public;

create or replace function pg_temp.approve_v328_workspace(p_business uuid)
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
  v_staff_chosen uuid := gen_random_uuid();
  v_staff_other uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_slug text := 'v328-' || v_business;
  v_result jsonb;
  v_decision jsonb;
  v_request uuid;
  v_appointment_staff uuid;
  -- A fixed midday two days out, anchored to SGT rather than "now + interval", so the fixture
  -- can never straddle midnight into a second calendar date regardless of when this test runs.
  v_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v328-owner-' || v_owner || '@example.test', '', now(), now(), now()
  );

  insert into public.businesses(
    id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm
  ) values (
    v_business, 'V328 Manual Confirm', v_slug, 'SGD', true, true, false
  );
  perform pg_temp.approve_v328_workspace(v_business);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V328 Branch', 'Asia/Singapore', true, true);

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V328 Owner', true, false),
    (v_staff_chosen, v_business, null, 'staff', 'V328 Chosen', true, true),
    (v_staff_other, v_business, null, 'staff', 'V328 Other', true, true);
  -- Both are free the whole day; round-robin (tie-break on created_at/name/id) would not
  -- reliably pick v_staff_chosen on its own, so a pass here proves the choice was honoured.
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_chosen, v_branch), (v_business, v_staff_other, v_branch);
  insert into public.staff_hours(business_id, staff_id, weekday, starts_at, ends_at)
  select v_business, staff_id, weekday, time '00:00', time '23:59'
    from (values (v_staff_chosen), (v_staff_other)) staff(staff_id)
    cross join generate_series(0, 6) weekday;

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service, v_business, 'V328 Service', 5000, 30, true, true);

  -- 1. submit with an explicit staff choice on a manual (auto-confirm off) business.
  v_result := public.internal_public_booking_submit(
    v_slug, 'V328 Customer', 'customer@example.com', null, v_service, 1,
    v_preferred, null, null, false,
    repeat('1', 64), repeat('2', 64), repeat('3', 64), null, v_staff_chosen);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a non-auto-confirm business must produce a pending request';
  assert (select staff_id from public.booking_requests where id = v_request) = v_staff_chosen,
    'the request must record the staff member the customer chose';

  -- 2. manual confirm with no staff override must land on the customer's choice, not round-robin.
  perform pg_temp.as_v328_user(v_owner);
  v_decision := public.staff_decide_booking_request_v73_v94_base(v_business, v_request, 'confirm', null);
  assert v_decision->>'outcome' = 'applied', 'the manual confirm must succeed';
  select appointment.staff_id into v_appointment_staff
    from public.appointments appointment
   where appointment.id = (v_decision->>'appointment_id')::uuid
     and appointment.business_id = v_business;
  assert v_appointment_staff = v_staff_chosen,
    'the confirmed appointment must be assigned to the staff member the customer chose, not round-robin';
  reset role;

  raise notice 'v328 verification passed (staff choice honoured on manual confirm)';
end $test$;

do $test2$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_staff_chosen uuid := gen_random_uuid();
  v_staff_fallback uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_slug text := 'v328b-' || v_business;
  v_result jsonb;
  v_decision jsonb;
  v_request uuid;
  v_appointment_staff uuid;
  v_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v328b-owner-' || v_owner || '@example.test', '', now(), now(), now()
  );

  insert into public.businesses(
    id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm
  ) values (
    v_business, 'V328 Fallback', v_slug, 'SGD', true, true, false
  );
  perform pg_temp.approve_v328_workspace(v_business);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V328 Fallback Branch', 'Asia/Singapore', true, true);

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V328 Owner', true, false),
    (v_staff_chosen, v_business, null, 'staff', 'V328 Chosen', true, true),
    (v_staff_fallback, v_business, null, 'staff', 'V328 Fallback', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_chosen, v_branch), (v_business, v_staff_fallback, v_branch);
  insert into public.staff_hours(business_id, staff_id, weekday, starts_at, ends_at)
  select v_business, staff_id, weekday, time '00:00', time '23:59'
    from (values (v_staff_chosen), (v_staff_fallback)) staff(staff_id)
    cross join generate_series(0, 6) weekday;

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service, v_business, 'V328 Fallback Service', 5000, 30, true, true);

  v_result := public.internal_public_booking_submit(
    v_slug, 'V328 Customer', 'customer@example.com', null, v_service, 1,
    v_preferred, null, null, false,
    repeat('4', 64), repeat('5', 64), repeat('6', 64), null, v_staff_chosen);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a non-auto-confirm business must produce a pending request';

  -- The chosen staff member is deactivated before the manual confirm runs — the confirm must
  -- still succeed by falling back to round-robin, not fail the whole decision.
  update public.staff set active = false where id = v_staff_chosen;

  perform pg_temp.as_v328_user(v_owner);
  v_decision := public.staff_decide_booking_request_v73_v94_base(v_business, v_request, 'confirm', null);
  assert v_decision->>'outcome' = 'applied',
    'the manual confirm must still succeed when the chosen staff member has since been deactivated';
  select appointment.staff_id into v_appointment_staff
    from public.appointments appointment
   where appointment.id = (v_decision->>'appointment_id')::uuid
     and appointment.business_id = v_business;
  assert v_appointment_staff is not null and v_appointment_staff <> v_staff_chosen,
    'a deactivated staff choice must fall back to round-robin, not the inactive staff member';
  reset role;

  raise notice 'v328 verification passed (fallback when the chosen staff member is gone)';
end $test2$;

rollback;
