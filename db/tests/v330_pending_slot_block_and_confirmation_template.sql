-- v330 rolled-back verification — pending booking_requests block availability, and businesses
-- gain a customer-facing WhatsApp confirmation template column.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Assertions cover:
--   1. booking_confirmation_template can be set/read on businesses (plain column, no RPC).
--   2. before any request exists, staff A's slot at the target time is offered.
--   3. once a pending request occupies staff A at that time, availability no longer offers that
--      exact slot for staff A, but the surrounding slots (30 min before/after) are untouched.
--   4. staff B, who was never asked, still offers that same time — the block is per-staff.
--   5. once the request is declined, the slot re-opens for staff A.

begin;

create or replace function pg_temp.as_v330_user(
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
grant execute on function pg_temp.as_v330_user(uuid, text) to public;

create or replace function pg_temp.approve_v330_workspace(p_business uuid)
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
  v_service uuid := gen_random_uuid();
  v_slug text := 'v330-' || v_business;
  v_result jsonb;
  v_out jsonb;
  v_request uuid;
  v_target_slot timestamptz;
  -- 60-minute service, so the 12:00 slot occupies 12:00-13:00; 11:30 and 13:00 must stay free.
  v_preferred timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner, 'authenticated',
    'authenticated', 'v330-owner-' || v_owner || '@example.test', '', now(), now(), now()
  );

  insert into public.businesses(
    id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm,
    enabled_modules
  ) values (
    v_business, 'V330 Slot Block', v_slug, 'SGD', true, true, false,
    array['dashboard','clients','sales','loyalty','retention','bookings','appointments']
  );
  perform pg_temp.approve_v330_workspace(v_business);

  -- 1. the template column is a plain, directly-writable field.
  update public.businesses set booking_confirmation_template = 'Hi {customer}, your {service} with {staff} on {date} at {time} is confirmed!' where id = v_business;
  assert (select booking_confirmation_template from public.businesses where id = v_business)
    = 'Hi {customer}, your {service} with {staff} on {date} at {time} is confirmed!',
    'booking_confirmation_template must round-trip as a plain column';

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V330 Branch', 'Asia/Singapore', true, true);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, weekday, time '00:00', time '23:59'
    from generate_series(0, 6) weekday;

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values
    (v_owner_staff, v_business, v_owner, 'owner', 'V330 Owner', true, false),
    (v_staff_a, v_business, null, 'staff', 'V330 Staff A', true, true),
    (v_staff_b, v_business, null, 'staff', 'V330 Staff B', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_a, v_branch), (v_business, v_staff_b, v_branch);
  update public.staff_hours set starts_at = time '00:00', ends_at = time '23:59'
   where staff_id in (v_staff_a, v_staff_b);

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service, v_business, 'V330 Service', 5000, 60, true, true);

  -- 2. before any request exists, staff A offers the target slot.
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff_a, (v_preferred at time zone 'Asia/Singapore')::date, 3, null);
  assert exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred
  ), 'staff A must offer the target slot before any request exists';

  -- submit a pending request for staff A at the target time.
  v_result := public.internal_public_booking_submit(
    v_slug, 'V330 Customer', 'customer@example.com', null, v_service, 1,
    v_preferred, null, null, false,
    repeat('1', 64), repeat('2', 64), repeat('3', 64), null, v_staff_a);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'a non-auto-confirm business must produce a pending request';

  -- 3. the exact slot is now withheld for staff A; the flanking slots are untouched.
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff_a, (v_preferred at time zone 'Asia/Singapore')::date, 3, null);
  assert not exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred
  ), 'a pending request must occupy its own slot so the next customer cannot double-book it';
  -- a 60-minute service starting 30 min before v_preferred would still overlap it (11:30-12:30
  -- overlaps 12:00-13:00) — the true nearest untouched slot is a full duration earlier, 11:00.
  assert exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred - interval '60 minutes'
  ), 'a slot a full duration before the pending request must stay free';
  assert exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred + interval '60 minutes'
  ), 'the slot immediately after the pending request ends must stay free';

  -- 4. staff B, who was never asked, still offers that exact time — the block is per-staff.
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff_b, (v_preferred at time zone 'Asia/Singapore')::date, 3, null);
  assert exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred
  ), 'a pending request against staff A must not block staff B';

  -- 5. once declined, the slot re-opens for staff A.
  perform pg_temp.as_v330_user(v_owner);
  perform public.staff_decide_booking_request_v73(v_business, v_request, 'decline', null);
  reset role;
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff_a, (v_preferred at time zone 'Asia/Singapore')::date, 3, null);
  assert exists (
    select 1 from jsonb_array_elements(v_out->'days') day, jsonb_array_elements(day->'slots') slot
     where (slot->>'at')::timestamptz = v_preferred
  ), 'declining the request must free the slot again';

  raise notice 'v330 verification passed';
end $test$;

rollback;
