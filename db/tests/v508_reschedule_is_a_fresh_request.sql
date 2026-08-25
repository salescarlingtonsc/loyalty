-- Rollback-only acceptance for nestly_v508 — a customer reschedule is a fresh booking request.
-- Run: supabase db query --linked -f db/tests/v508_reschedule_is_a_fresh_request.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Owner ruling (2026-08-25, photo 3): pressing reschedule must NOT create an appointment; it
-- files a fresh request the business approves or rejects, and the previously booked appointment
-- leaves the appointment list.
--
--   01  the reschedule call cancels the booked appointment and returns a pending request
--   02  the fresh request is VISIBLE in the customer's own list — the management token the
--       gateway normally mints was minted here too, or this row would be invisible
--   03  the fresh request is withdrawable through the existing v290 control
--   04  a replayed reschedule of the same appointment is refused (already_actioned), so a
--       double-tap cannot file two requests or cancel twice
--   05  another customer's session cannot reschedule this appointment (42501)
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v508_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v508_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v508-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_appt uuid := gen_random_uuid();
  v_staff uuid;
  v_new_at timestamptz := now() + interval '3 days';
  v_json jsonb;
  v_req uuid;
  v_txt text; v_n integer;
begin
  -- ==========================================================================================
  -- FIXTURE — a verified customer holding a booked future appointment
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V508 Acceptance', v_slug, array['loyalty','appointments','bookings'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v508-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_cust, 'authenticated', 'authenticated',
          'zz-v508-cust-' || substr(v_cust::text, 1, 8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_stranger, 'authenticated', 'authenticated',
          'zz-v508-str-' || substr(v_stranger::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  select id into v_staff from public.staff where business_id = v_biz and user_id = v_owner;
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V508 main', true, true);
  -- The v89 gate resolves through business_module_writable_at_v117, whose first clause is
  -- business_workspace_open_v94 — an unapproved workspace refuses every customer booking write.
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v508 acceptance',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;
  insert into public.services(id, business_id, name, duration_min, price_cents, active)
  values (v_service, v_biz, 'V508 Facial', 60, 8800, true);
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V508 Customer', '+65 9508 1001');
  -- app.v89_customer_booking_gate refuses any customer-attributed booking_requests row unless the
  -- business has customer booking switched ON — v508 rides the same gate as the portal, which is
  -- the point: rescheduling is booking.
  insert into public.business_customer_capabilities_v89(business_id, booking_enabled)
  values (v_biz, true) on conflict (business_id) do update set booking_enabled = true;
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_biz, v_identity, v_cust, v_client, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);
  -- staff_id NULL on purpose: app.guard_staff_blocked_time_v120 fail-closes on a staff member
  -- with no schedule, and a rota is not what this suite is about. The v508 writer copies whatever
  -- staff the appointment carries, so null exercises the nullable path too.
  insert into public.appointments(id, business_id, client_id, service_id, staff_id, branch_id,
                                  status, starts_at, ends_at)
  values (v_appt, v_biz, v_client, v_service, null, v_branch,
          'booked', now() + interval '1 day', now() + interval '1 day 1 hour');

  -- ==========================================================================================
  -- 01  THE RESCHEDULE: old appointment cancelled, fresh pending request returned
  -- ==========================================================================================
  perform pg_temp.as_v508_user(v_cust);
  v_json := public.customer_reschedule_appointment_v508(v_slug, v_appt, v_new_at, 'later please');
  v_req := (v_json ->> 'request_id')::uuid;
  select status into v_txt from public.appointments where id = v_appt;
  insert into _r values('01_replaced_atomically',
    case when v_json ->> 'status' = 'pending' and v_req is not null and v_txt = 'cancelled'
      then 'PASS one call: appointment cancelled, fresh request pending'
      else 'FAIL status=' || coalesce(v_json ->> 'status','null') || ' request='
           || coalesce(v_req::text,'null') || ' appointment=' || coalesce(v_txt,'null') end);
  select status into v_txt from public.booking_requests where id = v_req;
  insert into _r values('01_request_is_pending_for_business',
    case when v_txt = 'pending'
      then 'PASS the request sits on the business worklist in the same state a portal request does'
      else 'FAIL request status=' || coalesce(v_txt,'null') end);

  -- ==========================================================================================
  -- 02  VISIBLE IN THE CUSTOMER'S OWN LIST (the token join)
  -- ==========================================================================================
  v_json := public.customer_get_booking_requests(20, null);
  select count(*) into v_n
    from jsonb_array_elements(coalesce(v_json -> 'items', '[]'::jsonb)) row
   where (row ->> 'request_id')::uuid = v_req and row ->> 'status' = 'pending';
  insert into _r values('02_visible_to_customer',
    case when v_n = 1
      then 'PASS the fresh request appears in the customer''s Bookings list'
      else 'FAIL found ' || v_n || ' matching rows in ' || left(coalesce(v_json::text,'null'), 160) end);

  -- ==========================================================================================
  -- 03  WITHDRAWABLE THROUGH THE EXISTING CONTROL
  -- ==========================================================================================
  v_json := public.customer_withdraw_booking_request_v290(v_req);
  insert into _r values('03_withdrawable',
    case when v_json ->> 'status' = 'cancelled'
      then 'PASS the v290 Withdraw button works on a v508 request'
      else 'FAIL ' || coalesce(v_json::text,'null') end);

  -- ==========================================================================================
  -- 04  REPLAY REFUSED
  -- ==========================================================================================
  begin
    perform public.customer_reschedule_appointment_v508(v_slug, v_appt, v_new_at + interval '1 hour', null);
    insert into _r values('04_replay_refused','FAIL a second reschedule of a cancelled appointment succeeded');
  exception when others then
    insert into _r values('04_replay_refused',
      case when sqlerrm = 'already_actioned'
        then 'PASS a double-tap is refused rather than filing a second request'
        else 'FAIL unexpected error: ' || sqlerrm end);
  end;
  select count(*) into v_n from public.booking_requests
   where business_id = v_biz and customer_client_id = v_client;
  insert into _r values('04_exactly_one_request',
    case when v_n = 1 then 'PASS exactly one request exists after the replay attempt'
         else 'FAIL ' || v_n || ' requests' end);

  -- ==========================================================================================
  -- 05  A STRANGER IS REFUSED
  -- ==========================================================================================
  update public.appointments set status = 'booked' where id = v_appt;  -- rearm the target
  perform pg_temp.as_v508_user(v_stranger);
  begin
    perform public.customer_reschedule_appointment_v508(v_slug, v_appt, v_new_at, null);
    insert into _r values('05_stranger_refused','FAIL another account rescheduled someone else''s appointment');
  exception when others then
    insert into _r values('05_stranger_refused',
      case when sqlstate = '42501'
        then 'PASS an unlinked session is refused with 42501'
        else 'FAIL unexpected: [' || sqlstate || '] ' || sqlerrm end);
  end;
end $$;

select * from _r order by k;
rollback;
