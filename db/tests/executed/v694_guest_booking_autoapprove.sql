-- Rollback-only nestly_v694 acceptance: a GUEST booking auto-approves, reusing the customer the
-- manual confirmation would have used, and never creating a second one.
--
-- WHAT THE BUG WAS (audit W4G). app.v660_autoapprove_booking_request inserted the appointment
-- with booking_requests.customer_client_id. That column is only filled for a SIGNED-IN customer;
-- a guest files through public.request_booking and leaves it NULL. public.appointments.client_id
-- is NOT NULL, so the insert raised 23502 — and both callers wrap the helper in
-- `exception when others then null`. The firm had switched auto-approve on, a signed-in
-- customer's request confirmed instantly, and a guest's identical request sat 'new' forever with
-- nothing anywhere to say why.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--   1. POSITIVE CONTROL — a signed-in customer's request still auto-approves. If this fails the
--      fixture is broken and every assertion below is meaningless.
--   2. A GUEST request on the SAME business now auto-approves too: 'confirmed', with an
--      appointment. This is the assertion that fails on the pre-v694 function.
--   3. That appointment's client is a real public.clients row for the guest, matched on the
--      normalised phone — the same row app.upsert_portal_client would give the manual
--      confirmation.
--   4. NO DUPLICATE CUSTOMER: a second guest booking from the same phone reuses that one row.
--   5. A guest whose phone already belongs to an existing customer is recognised, not cloned.
--   6. A request auto-approve REFUSES (nobody free) creates no customer at all — the resolution
--      sits after the last refusal, so an unapproved request has no side effects.
--   7. The booking's marketing consent reaches the customer it created, and only that customer.
--   8. The audit row records the approval and marks it as a guest.
--
-- Assertions are recorded as rows so one SELECT reports the whole suite; a final gate makes any
-- FAIL fatal, because scripts/db-tests/run.mjs judges a file purely by psql's exit code.

begin;

create temp table v694_out(seq integer, step text, outcome text) on commit drop;

do $v694_test$
declare
  v_business uuid := gen_random_uuid();
  v_slug text := 'v694-' || replace(gen_random_uuid()::text, '-', '');
  v_branch uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_bound_client uuid := gen_random_uuid();
  v_bound_user uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_known_client uuid := gen_random_uuid();
  v_day date := ((now() at time zone 'Asia/Singapore')::date + 1);
  v_res jsonb;
  v_request uuid;
  v_appointment uuid;
  v_status text;
  v_client uuid;
  v_client_again uuid;
  v_count integer;
  v_consent boolean;
begin
  -- ----------------------------------------------------------------------------- FIXTURE
  insert into public.businesses(id, name, slug, industry, auto_approve_changes,
                                booking_staff_choice, booking_auto_confirm, is_synthetic,
                                enabled_modules)
  values (v_business, 'V694 Probe Salon', v_slug, 'beauty', true, true, false, true,
          array['dashboard','clients','sales','loyalty','retention','appointments','bookings']);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V694 Main', 'Asia/Singapore', true, true);

  -- app.staff_free_for_appointment_v47 needs opening hours that CONTAIN the whole appointment.
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, day.weekday, time '08:00', time '21:00'
    from generate_series(0, 6) as day(weekday);

  insert into public.staff(id, business_id, role, full_name, active, customer_bookable)
  values (v_staff, v_business, 'staff', 'V694 Team', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff, v_branch);

  insert into public.services(id, business_id, name, price_cents, duration_min,
                              active, show_on_booking_page)
  values (v_service, v_business, 'V694 Trim', 4500, 30, true, true);

  update public.business_customer_capabilities_v89
     set booking_enabled = true where business_id = v_business;
  update public.business_workspace_controls_v94
     set approval_status = 'approved', decided_at = now(), decision_reason = 'v694 fixture'
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused = false where business_id = v_business;
  insert into public.subscriptions(business_id, payment_status, status, current_period_end)
  values (v_business, 'paid', 'active', now() + interval '30 days');

  -- A signed-in, verified customer for the positive control.
  insert into auth.users(id, email) values (v_bound_user, 'v694.bound@example.com');
  insert into public.clients(id, business_id, full_name, phone, email)
  values (v_bound_client, v_business, 'V694 Bound', '+6581000001', 'v694.bound@example.com');
  insert into public.customer_identities(id, auth_user_id, status)
  values (v_identity, v_bound_user, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_business, v_identity, v_bound_user, v_bound_client,
          'verified', 'email_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);
  if app.resolve_verified_booking_client_v72(v_business, v_bound_user) is distinct from v_bound_client then
    raise exception 'FIXTURE: the signed-in customer is not bound to the probe business';
  end if;

  -- A customer this business already knows, for assertion 5.
  insert into public.clients(id, business_id, full_name, phone, email)
  values (v_known_client, v_business, 'V694 Known Already', '+6581000005', 'v694.known@example.com');

  -- ------------------------------------------------------------------ 1. positive control
  v_res := public.internal_public_booking_submit(
    v_slug, 'V694 Bound', 'v694.bound@example.com', '+6581000001', v_service,
    1, (v_day + time '09:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v694:t1:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:i1:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:f1:' || v_business::text, 'UTF8')), 'hex'),
    v_bound_user, v_staff, v_branch);
  if coalesce(v_res->>'status','') = 'confirmed'
     and nullif(v_res->>'appointment_id','') is not null then
    insert into v694_out values (1,'POSITIVE CONTROL: a signed-in customer''s request still auto-approves','PASS');
  else
    insert into v694_out values (1,'POSITIVE CONTROL: a signed-in customer''s request still auto-approves',
      format('FAIL - the fixture cannot auto-approve at all: %s', coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 2. the guest
  v_res := public.internal_public_booking_submit(
    v_slug, 'V694 Guest', 'v694.guest@example.com', '+6581000694', v_service,
    1, (v_day + time '11:00') at time zone 'Asia/Singapore', null, null, true,
    encode(sha256(convert_to('v694:t2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:i2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:f2:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  v_request := nullif(v_res->>'request_id','')::uuid;
  select request_row.status, request_row.appointment_id
    into v_status, v_appointment
    from public.booking_requests request_row where request_row.id = v_request;
  if v_status = 'confirmed' and v_appointment is not null then
    insert into v694_out values (2,'a GUEST request on an auto-approve business is confirmed with an appointment','PASS');
  else
    insert into v694_out values (2,'a GUEST request on an auto-approve business is confirmed with an appointment',
      format('FAIL - status=%s appointment=%s answer=%s',
             coalesce(v_status,'<null>'), coalesce(v_appointment::text,'<none>'), coalesce(v_res::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 3. the customer it used
  select appointment.client_id into v_client
    from public.appointments appointment where appointment.id = v_appointment;
  if v_client is not null
     and exists (select 1 from public.clients c
                  where c.id = v_client and c.business_id = v_business
                    and c.phone_norm = app.norm_phone('+6581000694')) then
    insert into v694_out values (3,'the appointment carries a real customer row for the guest, matched on normalised phone','PASS');
  else
    insert into v694_out values (3,'the appointment carries a real customer row for the guest, matched on normalised phone',
      format('FAIL - client=%s', coalesce(v_client::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. no duplicate customer
  v_res := public.internal_public_booking_submit(
    v_slug, 'V694 Guest Again', 'v694.guest.alt@example.com', '+6581000694', v_service,
    1, (v_day + time '13:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v694:t4:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:i4:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:f4:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  select appointment.client_id into v_client_again
    from public.appointments appointment
    join public.booking_requests request_row on request_row.appointment_id = appointment.id
   where request_row.id = nullif(v_res->>'request_id','')::uuid;
  select count(*) into v_count from public.clients c
   where c.business_id = v_business and c.phone_norm = app.norm_phone('+6581000694');
  if v_client_again = v_client and v_count = 1 then
    insert into v694_out values (4,'a second guest booking from the same phone reuses the SAME customer (no duplicate)','PASS');
  else
    insert into v694_out values (4,'a second guest booking from the same phone reuses the SAME customer (no duplicate)',
      format('FAIL - first=%s second=%s rows_with_that_phone=%s',
             coalesce(v_client::text,'<null>'), coalesce(v_client_again::text,'<null>'), v_count));
  end if;

  -- ------------------------------------------------------------------ 5. an existing customer
  v_res := public.internal_public_booking_submit(
    v_slug, 'V694 Known Already', 'v694.known@example.com', '+6581000005', v_service,
    1, (v_day + time '15:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v694:t5:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:i5:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:f5:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  select appointment.client_id into v_client_again
    from public.appointments appointment
    join public.booking_requests request_row on request_row.appointment_id = appointment.id
   where request_row.id = nullif(v_res->>'request_id','')::uuid;
  select count(*) into v_count from public.clients c
   where c.business_id = v_business and c.phone_norm = app.norm_phone('+6581000005');
  if v_client_again = v_known_client and v_count = 1 then
    insert into v694_out values (5,'a guest whose phone the business already knows is recognised, not cloned','PASS');
  else
    insert into v694_out values (5,'a guest whose phone the business already knows is recognised, not cloned',
      format('FAIL - booked_for=%s expected=%s rows_with_that_phone=%s',
             coalesce(v_client_again::text,'<null>'), v_known_client, v_count));
  end if;

  -- ------------------------------------------------------------------ 6. a refusal costs nothing
  -- The only bookable team member is deactivated, so auto-approve runs out of staff and refuses.
  -- The customer must NOT be created as a side effect of a request nobody approved.
  update public.staff set active = false where id = v_staff;
  v_res := public.internal_public_booking_submit(
    v_slug, 'V694 Nobody Free', 'v694.nobody@example.com', '+6581000006', v_service,
    1, (v_day + time '17:00') at time zone 'Asia/Singapore', null, null, true,
    encode(sha256(convert_to('v694:t6:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:i6:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v694:f6:' || v_business::text, 'UTF8')), 'hex'),
    null, null, v_branch);
  select request_row.status into v_status
    from public.booking_requests request_row
   where request_row.id = nullif(v_res->>'request_id','')::uuid;
  select count(*) into v_count from public.clients c
   where c.business_id = v_business and c.phone_norm = app.norm_phone('+6581000006');
  update public.staff set active = true where id = v_staff;
  if v_status in ('new','pending') and v_count = 0 then
    insert into v694_out values (6,'a request auto-approve REFUSES stays pending and creates no customer','PASS');
  else
    insert into v694_out values (6,'a request auto-approve REFUSES stays pending and creates no customer',
      format('FAIL - status=%s customers_created=%s', coalesce(v_status,'<null>'), v_count));
  end if;

  -- ------------------------------------------------------------------ 7. consent follows the booking
  select c.marketing_consent into v_consent from public.clients c
   where c.business_id = v_business and c.phone_norm = app.norm_phone('+6581000694');
  select count(*) into v_count from public.consents cons
   where cons.business_id = v_business and cons.client_id = v_client
     and cons.channel = 'marketing' and cons.action = 'granted';
  if v_consent and v_count >= 1 then
    insert into v694_out values (7,'the guest who ticked marketing consent is recorded as consenting, with a consents row','PASS');
  else
    insert into v694_out values (7,'the guest who ticked marketing consent is recorded as consenting, with a consents row',
      format('FAIL - marketing_consent=%s consent_rows=%s', coalesce(v_consent::text,'<null>'), v_count));
  end if;

  -- ------------------------------------------------------------------ 8. the approval is audited
  if exists (select 1 from public.audit_log log
              where log.business_id = v_business
                and log.action = 'booking_request.auto_approved_v660'
                and log.entity_id = v_request
                and (log.detail->>'guest')::boolean
                and (log.detail->>'client_id')::uuid = v_client) then
    insert into v694_out values (8,'the guest approval is recorded in audit_log, naming the customer it used','PASS');
  else
    insert into v694_out values (8,'the guest approval is recorded in audit_log, naming the customer it used',
      'FAIL - no auto_approved_v660 row marked guest for this request');
  end if;
end
$v694_test$;

select seq, step, outcome from v694_out order by seq;

do $v694_gate$
declare v_bad integer; v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v694_out;
  if v_all <> 8 then
    raise exception 'nestly_v694: % of 8 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v694: % assertion(s) FAILED: %', v_bad,
      (select string_agg(seq || ' ' || step || ' => ' || outcome, ' || ')
         from v694_out where outcome not like 'PASS%');
  end if;
end
$v694_gate$;

rollback;
