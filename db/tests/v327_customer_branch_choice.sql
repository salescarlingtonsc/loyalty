-- v327 rolled-back verification — customer-chosen branch for multi-branch bookings.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Assertions cover:
--   1. a single-branch business exposes no branches[] at all (fail closed, matches v183);
--   2. a multi-branch business exposes branches[] and per-staff branch_ids;
--   3. availability filters the roster to staff assigned to the chosen branch, and returns
--      nobody when the requested staff/branch pairing does not exist;
--   4. submit rejects a foreign/inactive branch and a staff/branch mismatch, and records the
--      customer's branch choice on the request;
--   5. a manual (non-auto-confirm) staff decision honours the customer's branch choice over
--      the shop default when the staff member confirming leaves no explicit override.

begin;

create or replace function pg_temp.as_v327_user(
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
grant execute on function pg_temp.as_v327_user(uuid, text) to public;

create or replace function pg_temp.approve_v327_workspace(p_business uuid)
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
  v_branch_a uuid := gen_random_uuid();
  v_branch_b uuid := gen_random_uuid();
  v_single_business uuid := gen_random_uuid();
  v_single_branch uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_staff_a uuid := gen_random_uuid();
  v_staff_b uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_slug text := 'v327-' || v_business;
  v_single_slug text := 'v327-single-' || v_single_business;
  v_page jsonb;
  v_out jsonb;
  v_result jsonb;
  v_request uuid;
  v_appointment_branch uuid;
  v_decision jsonb;
  -- A fixed midday two days out, anchored to SGT rather than "now + interval", so the fixture
  -- can never straddle midnight into a second calendar date regardless of when this test runs.
  v_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v327-owner-' || v_owner || '@example.test', '', now(), now(), now()
  );

  -- enabled_modules defaults to dashboard/clients/sales/loyalty/retention only — 'bookings'
  -- and 'appointments' must be explicit, or the owner's manual-confirm in assertion 5 42501s
  -- on app.staff_module_mode_v94 before ever reaching the branch fallback being tested.
  insert into public.businesses(id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm, enabled_modules)
  values (v_business, 'V327 Multi Branch', v_slug, 'SGD', true, true, false,
    array['dashboard','clients','sales','loyalty','retention','bookings','appointments']);
  insert into public.businesses(id, name, slug, currency, is_synthetic)
  values (v_single_business, 'V327 Single Branch', v_single_slug, 'SGD', true);
  perform pg_temp.approve_v327_workspace(v_business);
  perform pg_temp.approve_v327_workspace(v_single_business);

  -- branch_b is the DEFAULT — the customer will deliberately choose branch_a, so a fix that
  -- silently fell back to "the default branch" would be caught by assertion 5 below.
  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values
    (v_branch_a, v_business, 'V327 Branch A', 'Asia/Singapore', true, false),
    (v_branch_b, v_business, 'V327 Branch B', 'Asia/Singapore', true, true);
  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_single_branch, v_single_business, 'V327 Only Branch', 'Asia/Singapore', true, true);

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V327 Owner', true, false),
    (v_staff_a, v_business, null, 'staff', 'V327 Staff A', true, true),
    (v_staff_b, v_business, null, 'staff', 'V327 Staff B', true, true);
  -- Owner needs no staff_branches row (owner/admin see every branch per v17). Only staff A is
  -- assigned to branch A, and only staff A gets a rota, so the manual-confirm round-robin in
  -- assertion 5 has exactly one eligible, free person and cannot pick anyone else by accident.
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values
    (v_business, v_staff_a, v_branch_a),
    (v_business, v_staff_b, v_branch_b);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, branch_id, weekday, time '00:00', time '23:59'
    from (values (v_branch_a), (v_branch_b)) branches(branch_id)
    cross join generate_series(0, 6) weekday;
  insert into public.staff_hours(business_id, staff_id, weekday, starts_at, ends_at)
  select v_business, v_staff_a, weekday, time '00:00', time '23:59'
    from generate_series(0, 6) weekday;

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service, v_business, 'V327 Service', 5000, 30, true, true);

  -- 1. a single-branch business must never expose branch identity.
  v_page := public.internal_public_booking_page(v_single_slug);
  assert v_page->'branches' = '[]'::jsonb, 'a single active branch must not expose branches[]';

  -- 2. a multi-branch business exposes both branches, and each staff member's branch_ids.
  v_page := public.internal_public_booking_page(v_slug);
  assert jsonb_array_length(v_page->'branches') = 2, 'both active branches must be listed';
  assert (
    select bool_and((member->'branch_ids') is not null)
      from jsonb_array_elements(v_page->'staff') member
  ), 'every staff entry must carry branch_ids';
  assert (
    select (member->'branch_ids') = jsonb_build_array(v_branch_a)
      from jsonb_array_elements(v_page->'staff') member
     where (member->>'id')::uuid = v_staff_a
  ), 'staff A must be scoped to branch A only';

  -- 3. availability filters the roster by branch.
  v_out := public.internal_public_booking_availability(v_slug, v_service, null, null, 3, v_branch_a);
  assert jsonb_array_length(v_out->'staff') = 1, 'branch A must offer exactly one team member';
  assert (v_out->'staff'->0->>'id')::uuid = v_staff_a, 'branch A must offer staff A, not staff B';

  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff_b, null, 3, v_branch_a);
  assert v_out->'staff' = '[]'::jsonb,
    'asking for staff B at branch A must offer nobody, not staff B anyway';

  -- 4. submit validates branch identity and records the customer''s choice.
  begin
    perform public.internal_public_booking_submit(
      v_slug, 'Test', 'test@example.com', null, v_service, 1,
      v_preferred, null, null, false,
      repeat('a', 64), repeat('b', 64), repeat('c', 64), null, null,
      '00000000-0000-4000-8000-000000000000'::uuid);
    raise exception 'expected a foreign branch id to be rejected';
  exception when sqlstate '22023' then null;
  end;

  begin
    perform public.internal_public_booking_submit(
      v_slug, 'Test', 'test@example.com', null, v_service, 1,
      v_preferred, null, null, false,
      repeat('d', 64), repeat('e', 64), repeat('f', 64), null, v_staff_b, v_branch_a);
    raise exception 'expected a staff/branch mismatch to be rejected';
  exception when sqlstate '22023' then null;
  end;

  v_result := public.internal_public_booking_submit(
    v_slug, 'V327 Customer', 'customer@example.com', null, v_service, 1,
    v_preferred, null, null, false,
    repeat('1', 64), repeat('2', 64), repeat('3', 64), null, v_staff_a, v_branch_a);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a non-auto-confirm business must produce a pending request';
  assert (select branch_id from public.booking_requests where id = v_request) = v_branch_a,
    'the request must record the branch the customer chose';
  assert (select staff_id from public.booking_requests where id = v_request) = v_staff_a,
    'the request must still record the staff member the customer chose';

  -- 5. manual confirm: with no staff override, the CUSTOMER''s branch choice must win over the
  --    shop default (branch_b is_default = true, but the customer asked for branch_a).
  perform pg_temp.as_v327_user(v_owner);
  v_decision := public.staff_decide_booking_request_v73(v_business, v_request, 'confirm', null);
  assert v_decision->>'outcome' = 'applied', 'the manual confirm must succeed';
  select appointment.branch_id into v_appointment_branch
    from public.appointments appointment
   where appointment.id = (v_decision->>'appointment_id')::uuid
     and appointment.business_id = v_business;
  assert v_appointment_branch = v_branch_a,
    'the confirmed appointment must land at the branch the customer asked for, not the shop default';
  reset role;

  raise notice 'v327 verification passed';
end $test$;

rollback;
