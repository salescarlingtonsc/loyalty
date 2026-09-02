-- Rollback-only v678 acceptance suite — auto-approve honours the customer's staff and branch.
--
-- The fixture is built so that the defect cannot pass by luck. app.v660_autoapprove_booking_request
-- resolves an unstated preference with `order by candidate.staff_id limit 1`, so the team member
-- the customer ASKS FOR is deliberately the one whose uuid sorts SECOND, and the branch asked for
-- is deliberately NOT the default. Before v678 both tests below booked the other person at the
-- other shop; the fixture asserts that ordering up front so a future uuid change cannot quietly
-- turn these into tautologies.
--
-- SECTION 0 — the fixture states the trap it is testing.
--   S0-T1  The chosen team member sorts AFTER the other one, and the chosen branch is not default.
--
-- SECTION 1 — a stated choice is honoured.
--   S1-T1  The submit reports 'confirmed' and auto_approved, not the hard-coded 'pending'.
--   S1-T2  The appointment carries the CHOSEN team member, not the first free one.
--   S1-T3  The appointment carries the CHOSEN branch, not the default one.
--   S1-T4  The request itself is confirmed and carries the same staff, branch and appointment.
--   S1-T5  The stored idempotency answer says 'confirmed' too, so a replay tells the same story.
--   S1-T6  Replaying the submission returns the confirmed answer, not 'pending'.
--
-- SECTION 2 — no choice stated: the v660 behaviour is unchanged.
--   S2-T1  Still auto-approved.
--   S2-T2  Still the first free team member by uuid, at the default branch.
--
-- SECTION 3 — a choice that cannot be met fails closed instead of substituting.
--   S3-T1  The chosen member being busy leaves the request pending, as the inner submit said.
--   S3-T2  No appointment was created for anybody else at that time.
--
-- Everything is inside one transaction that rolls back; the fixture business never survives.
begin;
create temporary table v678_evidence(test text, detail text) on commit drop;

do $v678$
declare
  v_business uuid := gen_random_uuid();
  v_slug text := 'v678-' || replace(gen_random_uuid()::text, '-', '');
  v_branch_default uuid := gen_random_uuid();
  v_branch_other uuid := gen_random_uuid();
  v_staff_one uuid := gen_random_uuid();
  v_staff_two uuid := gen_random_uuid();
  v_staff_first uuid;                 -- the one v660 picks when nobody is named
  v_staff_chosen uuid;                -- the one the customer names: deliberately NOT the above
  v_service uuid := gen_random_uuid();
  -- The signed-in (bound) customer. v660 inserts the appointment with the request's
  -- customer_client_id, and public.appointments.client_id is NOT NULL, so auto-approve can only
  -- ever complete for a customer who is linked to the business — which is exactly the path the
  -- live occurrence took (Cubbly SPA, 2026-08-31).
  v_client uuid := gen_random_uuid();
  v_auth_user uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_day date := ((now() at time zone 'Asia/Singapore')::date + 1);
  v_slot_choice timestamptz;
  v_slot_anyone timestamptz;
  v_slot_busy timestamptz;
  v_weekday smallint;
  v_res jsonb;
  v_request uuid;
  v_appointment uuid;
  v_staff_booked uuid;
  v_branch_booked uuid;
  v_status text;
  v_stored jsonb;
  v_key text;
  v_count integer;
begin
  v_staff_first := least(v_staff_one, v_staff_two);
  v_staff_chosen := greatest(v_staff_one, v_staff_two);
  v_slot_choice := (v_day + time '10:00') at time zone 'Asia/Singapore';
  v_slot_anyone := (v_day + time '14:00') at time zone 'Asia/Singapore';
  v_slot_busy   := (v_day + time '16:00') at time zone 'Asia/Singapore';

  -- ---------------------------------------------------------------- FIXTURE
  insert into public.businesses(id, name, slug, industry, auto_approve_changes,
                                booking_staff_choice, booking_auto_confirm, is_synthetic,
                                enabled_modules)
  values (v_business, 'V678 Probe Salon', v_slug, 'beauty', true, true, false, true,
          array['dashboard','clients','sales','loyalty','retention','appointments','bookings']);

  -- Two separate statements, and the second one paid for: app.assign_branch_billing_state_v665
  -- switches OFF any branch after the first unless it arrives already billed, and an inactive
  -- branch is not offered to a customer at all — which would make the branch test vacuous.
  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch_default, v_business, 'V678 Default', 'Asia/Singapore', true, true);
  insert into public.branches(id, business_id, name, timezone, active, is_default, billing_state)
  values (v_branch_other, v_business, 'V678 Other', 'Asia/Singapore', true, false, 'active');
  if not exists (select 1 from public.branches branch_row
                  where branch_row.id = v_branch_other and branch_row.active) then
    raise exception 'FIXTURE: the second branch did not come up active';
  end if;

  -- v47 requires an opening-hours row that CONTAINS the whole appointment, on every branch it is
  -- asked about — not merely "no rows configured". Open wide enough for all three slots.
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, branch.id, day.weekday, time '08:00', time '21:00'
    from (values (v_branch_default), (v_branch_other)) as branch(id),
         generate_series(0, 6) as day(weekday);

  insert into public.staff(id, business_id, role, full_name, active, customer_bookable)
  values (v_staff_one, v_business, 'staff', 'V678 Team One', true, true),
         (v_staff_two, v_business, 'staff', 'V678 Team Two', true, true);

  -- Both are assigned to both branches, so the branch test turns on the customer's choice and
  -- not on which person happens to work where.
  insert into public.staff_branches(business_id, staff_id, branch_id)
  select v_business, member.id, branch.id
    from (values (v_staff_one), (v_staff_two)) as member(id),
         (values (v_branch_default), (v_branch_other)) as branch(id);

  insert into public.services(id, business_id, name, price_cents, duration_min,
                              active, show_on_booking_page)
  values (v_service, v_business, 'V678 Trim', 4500, 30, true, true);

  -- app.v89_customer_booking_gate refuses a bound booking unless the business has the customer
  -- booking capability AND an operational workspace with the bookings module writable, so the
  -- seeded control rows are brought to that state rather than the request being filed as a guest.
  update public.business_customer_capabilities_v89
     set booking_enabled = true where business_id = v_business;
  update public.business_workspace_controls_v94
     set approval_status = 'approved', decided_at = now(), decision_reason = 'v678 fixture'
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused = false where business_id = v_business;
  insert into public.subscriptions(business_id, payment_status, status, current_period_end)
  values (v_business, 'paid', 'active', now() + interval '30 days');
  if not app.v89_business_module_enabled(v_business, 'bookings') then
    raise exception 'FIXTURE: the bookings module is not writable for the probe business';
  end if;

  insert into auth.users(id, email) values (v_auth_user, 'v678.customer@example.com');
  insert into public.clients(id, business_id, full_name, phone, email)
  values (v_client, v_business, 'V678 Customer', '+6581000678', 'v678.customer@example.com');
  insert into public.customer_identities(id, auth_user_id, status)
  values (v_identity, v_auth_user, 'active');
  -- app.v31_link_immutable_guard only accepts a link whose id the caller has declared.
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_business, v_identity, v_auth_user, v_client, 'verified', 'email_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);
  if app.resolve_verified_booking_client_v72(v_business, v_auth_user) is distinct from v_client then
    raise exception 'FIXTURE: the customer is not bound to the probe business';
  end if;

  -- ---------------------------------------------------------------- SECTION 0
  if v_staff_chosen <= v_staff_first then
    raise exception 'S0-T1 FAIL: fixture broken — the chosen member does not sort second';
  end if;
  if v_branch_other = v_branch_default
     or v_branch_default is distinct from app.default_branch(v_business) then
    raise exception 'S0-T1 FAIL: fixture broken — the default branch is not the one expected';
  end if;
  v_weekday := extract(dow from v_slot_choice at time zone 'Asia/Singapore')::smallint;
  insert into v678_evidence values('S0-T1',
    'chosen staff sorts second; chosen branch is not the default; weekday ' || v_weekday);

  -- ---------------------------------------------------------------- SECTION 1
  v_key := encode(sha256(convert_to('v678:choice:' || v_business::text, 'UTF8')), 'hex');
  v_res := public.internal_public_booking_submit(
    v_slug, 'V678 Customer', 'v678.customer@example.com', null, v_service,
    1, v_slot_choice, null, null, false,
    encode(sha256(convert_to('v678:token:' || v_business::text, 'UTF8')), 'hex'),
    v_key,
    encode(sha256(convert_to('v678:fp:' || v_business::text, 'UTF8')), 'hex'),
    v_auth_user, v_staff_chosen, v_branch_other);

  if v_res is null then raise exception 'S1-T1 FAIL: the submit returned nothing'; end if;
  if v_res->>'status' <> 'confirmed' then
    raise exception 'S1-T1 FAIL: the customer was told %, but the request was auto-approved',
      coalesce(v_res->>'status', 'null');
  end if;
  if not coalesce((v_res->>'auto_approved')::boolean, false) then
    raise exception 'S1-T1 FAIL: auto_approved was not reported';
  end if;
  v_request := nullif(v_res->>'request_id', '')::uuid;
  v_appointment := nullif(v_res->>'appointment_id', '')::uuid;
  if v_request is null or v_appointment is null then
    raise exception 'S1-T1 FAIL: request % / appointment % missing from the answer',
      coalesce(v_request::text, 'null'), coalesce(v_appointment::text, 'null');
  end if;
  insert into v678_evidence values('S1-T1', 'answer: confirmed, auto_approved, appointment returned');

  select appointment.staff_id, appointment.branch_id
    into v_staff_booked, v_branch_booked
    from public.appointments appointment where appointment.id = v_appointment;
  if v_staff_booked is distinct from v_staff_chosen then
    raise exception 'S1-T2 FAIL: booked % but the customer asked for %',
      coalesce(v_staff_booked::text, 'nobody'), v_staff_chosen;
  end if;
  insert into v678_evidence values('S1-T2', 'the appointment is with the team member who was asked for');

  if v_branch_booked is distinct from v_branch_other then
    raise exception 'S1-T3 FAIL: booked at branch % but the customer asked for %',
      coalesce(v_branch_booked::text, 'none'), v_branch_other;
  end if;
  insert into v678_evidence values('S1-T3', 'the appointment is at the branch that was asked for');

  select request_row.status, request_row.staff_id, request_row.branch_id
    into v_status, v_staff_booked, v_branch_booked
    from public.booking_requests request_row where request_row.id = v_request;
  if v_status <> 'confirmed' then
    raise exception 'S1-T4 FAIL: the request is % rather than confirmed', v_status; end if;
  if v_staff_booked is distinct from v_staff_chosen
     or v_branch_booked is distinct from v_branch_other then
    raise exception 'S1-T4 FAIL: the request does not carry the choice it was filed with'; end if;
  if not exists (select 1 from public.booking_requests request_row
                  where request_row.id = v_request
                    and request_row.appointment_id = v_appointment) then
    raise exception 'S1-T4 FAIL: the request is not joined to the appointment it caused'; end if;
  insert into v678_evidence values('S1-T4', 'the request row agrees with the appointment');

  select token.initial_response into v_stored
    from app.booking_management_tokens token
   where token.booking_request_id = v_request;
  if coalesce(v_stored->>'status', '') <> 'confirmed' then
    raise exception 'S1-T5 FAIL: the stored answer still says %',
      coalesce(v_stored->>'status', 'null'); end if;
  insert into v678_evidence values('S1-T5', 'the stored idempotency answer says confirmed');

  v_res := public.internal_public_booking_submit(
    v_slug, 'V678 Customer', 'v678.customer@example.com', null, v_service,
    1, v_slot_choice, null, null, false,
    encode(sha256(convert_to('v678:token:' || v_business::text, 'UTF8')), 'hex'),
    v_key,
    encode(sha256(convert_to('v678:fp:' || v_business::text, 'UTF8')), 'hex'),
    v_auth_user, v_staff_chosen, v_branch_other);
  if not coalesce((v_res->>'replayed')::boolean, false) then
    raise exception 'S1-T6 FAIL: the second identical submission was not recognised as a replay'; end if;
  if v_res->>'status' <> 'confirmed' then
    raise exception 'S1-T6 FAIL: the replay said % rather than confirmed', v_res->>'status'; end if;
  insert into v678_evidence values('S1-T6', 'the replay repeats the confirmed answer');

  -- ---------------------------------------------------------------- SECTION 2
  v_res := public.internal_public_booking_submit(
    v_slug, 'V678 Anyone', 'v678.anyone@example.com', null, v_service,
    1, v_slot_anyone, null, null, false,
    encode(sha256(convert_to('v678:token2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v678:key2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v678:fp2:' || v_business::text, 'UTF8')), 'hex'),
    v_auth_user, null, null);
  if v_res->>'status' <> 'confirmed' then
    raise exception 'S2-T1 FAIL: a no-choice booking said % rather than confirmed',
      coalesce(v_res->>'status', 'null'); end if;
  v_appointment := nullif(v_res->>'appointment_id', '')::uuid;
  if v_appointment is null then
    raise exception 'S2-T1 FAIL: a no-choice booking produced no appointment'; end if;
  insert into v678_evidence values('S2-T1', 'a booking with no stated preference is still auto-approved');

  select appointment.staff_id, appointment.branch_id
    into v_staff_booked, v_branch_booked
    from public.appointments appointment where appointment.id = v_appointment;
  if v_staff_booked is distinct from v_staff_first then
    raise exception 'S2-T2 FAIL: the unnamed booking went to % rather than the first free member %',
      coalesce(v_staff_booked::text, 'nobody'), v_staff_first; end if;
  if v_branch_booked is distinct from v_branch_default then
    raise exception 'S2-T2 FAIL: the unnamed booking went to branch % rather than the default',
      coalesce(v_branch_booked::text, 'none'); end if;
  insert into v678_evidence values('S2-T2',
    'unchanged v660 behaviour: first free member by uuid, at the default branch');

  -- ---------------------------------------------------------------- SECTION 3
  -- The chosen member is already busy at this slot. The correct outcome is a pending request for
  -- a human, NOT a silent substitute — the sub-case F062 called out.
  insert into public.appointments(business_id, client_id, staff_id, branch_id, service_id,
                                  starts_at, ends_at, status, party_size, source)
  values (v_business, v_client, v_staff_chosen, v_branch_other, v_service,
          v_slot_busy, v_slot_busy + interval '30 minutes', 'booked', 1, 'portal');

  v_res := public.internal_public_booking_submit(
    v_slug, 'V678 Insistent', 'v678.insistent@example.com', null, v_service,
    1, v_slot_busy, null, null, false,
    encode(sha256(convert_to('v678:token3:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v678:key3:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v678:fp3:' || v_business::text, 'UTF8')), 'hex'),
    v_auth_user, v_staff_chosen, v_branch_other);
  if v_res->>'status' = 'confirmed' then
    raise exception 'S3-T1 FAIL: a busy team member was substituted instead of leaving it pending'; end if;
  v_request := nullif(v_res->>'request_id', '')::uuid;
  select request_row.status into v_status
    from public.booking_requests request_row where request_row.id = v_request;
  if v_status = 'confirmed' then
    raise exception 'S3-T1 FAIL: the request was confirmed although the chosen member was busy'; end if;
  if exists (select 1 from public.booking_requests request_row
              where request_row.id = v_request and request_row.appointment_id is not null) then
    raise exception 'S3-T1 FAIL: a pending request carries an appointment'; end if;
  insert into v678_evidence values('S3-T1',
    'a busy chosen member leaves the request ' || v_status || ' for a human');

  select count(*) into v_count
    from public.appointments appointment
   where appointment.business_id = v_business
     and appointment.starts_at = v_slot_busy;
  if v_count <> 1 then
    raise exception 'S3-T2 FAIL: % appointments exist at the busy slot, expected only the fixture one',
      v_count; end if;
  insert into v678_evidence values('S3-T2', 'no substitute appointment was created at the busy slot');
end
$v678$;

select test, detail from v678_evidence order by test;

rollback;
