-- Rollback-only nestly_v695 acceptance: "Anyone available" on a staff reschedule really does
-- un-assign the request, and everything else about the RPC is unchanged.
--
-- WHAT THE BUG WAS (audit W4G). public.staff_reschedule_and_confirm_booking_request_v329 applied
-- the staff choice as `staff_id = coalesce(p_staff, staff_id)`. NULL was the only way to say
-- "nobody", and coalesce reads NULL as "leave it alone". W3B/F075 had already made
-- "Anyone available" a real option in both reschedule forms, whose empty value reaches the RPC as
-- p_staff:null — so a request that arrived unassigned stayed unassigned (which F075 tested), but
-- a request the customer filed WITH a named team member could not be un-assigned at all. Staff
-- were told the move applied and the original person was booked anyway.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself, as the real owner principal:
--   1. Exactly ONE overload of the RPC exists — two would answer a named-argument PostgREST call
--      with PGRST203, which is how v410 blocked every promotion save.
--   2. p_clear_staff => true clears an assignment the customer had made: the request AND the
--      appointment it produces are both unassigned. This is the assertion that fails on v329.
--   3. p_staff => null WITHOUT the flag still means "unchanged" — the four-argument call keeps
--      its behaviour, so nothing that was not updated is broken.
--   4. p_staff => a member still assigns that member.
--   5. Naming a member AND asking to clear is refused (22023), not silently resolved, and the
--      request is left exactly as it was.
--   6. The bookings write guard still refuses a caller who is not a member of the business
--      (42501), so the new parameter did not become a way in.
--
-- Assertions are recorded as rows; a final gate makes any FAIL fatal.

begin;

create temp table v695_out(seq integer, step text, outcome text) on commit drop;

create or replace function pg_temp.as_v695_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;

create or replace function pg_temp.as_v695_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text, true);
end
$$;

do $v695_test$
declare
  v_business uuid := gen_random_uuid();
  v_slug text := 'v695-' || replace(gen_random_uuid()::text, '-', '');
  v_branch uuid := gen_random_uuid();
  v_staff uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_blocker_client uuid := gen_random_uuid();
  v_day date := ((now() at time zone 'Asia/Singapore')::date + 1);
  v_request uuid;
  v_res jsonb;
  v_after uuid;
  v_appt_staff uuid;
  v_count integer;
  v_err text;
begin
  -- ----------------------------------------------------------------------------- FIXTURE
  perform pg_temp.as_v695_system();
  insert into auth.users(id, email) values (v_owner, 'v695.owner@example.com');
  insert into auth.users(id, email) values (v_outsider, 'v695.outsider@example.com');

  insert into public.businesses(id, name, slug, industry, auto_approve_changes,
                                booking_staff_choice, booking_auto_confirm, is_synthetic,
                                enabled_modules)
  values (v_business, 'V695 Probe Salon', v_slug, 'beauty', false, true, false, true,
          array['dashboard','clients','sales','loyalty','retention','appointments','bookings']);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V695 Main', 'Asia/Singapore', true, true);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, day.weekday, time '08:00', time '21:00'
    from generate_series(0, 6) as day(weekday);

  insert into public.staff(id, business_id, role, full_name, active, customer_bookable)
  values (v_staff, v_business, 'staff', 'V695 Asked For', true, true),
         (v_other, v_business, 'staff', 'V695 Someone Else', true, true);
  insert into public.staff(id, business_id, user_id, role, full_name, active, access_state)
  values (v_owner_staff, v_business, v_owner, 'owner', 'V695 Owner', true, 'approved');
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff, v_branch),
         (v_business, v_other, v_branch),
         (v_business, v_owner_staff, v_branch);

  insert into public.services(id, business_id, name, price_cents, duration_min,
                              active, show_on_booking_page)
  values (v_service, v_business, 'V695 Trim', 4500, 30, true, true);

  update public.business_customer_capabilities_v89
     set booking_enabled = true where business_id = v_business;
  update public.business_workspace_controls_v94
     set approval_status = 'approved', decided_at = now(), decision_reason = 'v695 fixture'
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused = false where business_id = v_business;
  insert into public.subscriptions(business_id, payment_status, status, current_period_end)
  values (v_business, 'paid', 'active', now() + interval '30 days');

  -- ------------------------------------------------------------------ 1. one overload only
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'staff_reschedule_and_confirm_booking_request_v329';
  if v_count = 1 then
    insert into v695_out values (1,'exactly one overload of the reschedule RPC exists (no PGRST203)','PASS');
  else
    insert into v695_out values (1,'exactly one overload of the reschedule RPC exists (no PGRST203)',
      format('FAIL - %s overloads', v_count));
  end if;

  -- ------------------------------------------------------------------ 2. clearing works
  -- The trap is deliberate: the team member the customer named is BUSY at the new time. If the
  -- clear does not take, staff_decide_booking_request_v73 still resolves v_request.staff_id,
  -- books in 'manual' mode against a member who is not free, and returns a scheduling_conflict —
  -- which is exactly what v329 did. Only a genuinely un-assigned request falls through to
  -- round-robin and lands on somebody who IS free. Two observable differences, one cause: pre-v695
  -- this assertion fails on the outcome ('scheduling_conflict') as well as on the staff member.
  insert into public.clients(id, business_id, full_name, phone)
  values (v_blocker_client, v_business, 'V695 Blocker', '+6581000209');
  insert into public.appointments(business_id, client_id, staff_id, branch_id, service_id,
                                  starts_at, ends_at, status, source)
  values (v_business, v_blocker_client, v_staff, v_branch, v_service,
          (v_day + time '10:00') at time zone 'Asia/Singapore',
          (v_day + time '10:30') at time zone 'Asia/Singapore', 'booked', 'walk_in');

  v_res := public.internal_public_booking_submit(
    v_slug, 'V695 Guest A', 'v695.a@example.com', '+6581000201', v_service,
    1, (v_day + time '09:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v695:t2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:i2:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:f2:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  v_request := nullif(v_res->>'request_id','')::uuid;
  if (select staff_id from public.booking_requests where id = v_request) is distinct from v_staff then
    raise exception 'FIXTURE: the request did not record the team member the customer asked for';
  end if;
  if app.staff_free_for_appointment_v47(v_business, v_staff, v_branch, v_service,
       (v_day + time '10:00') at time zone 'Asia/Singapore',
       (v_day + time '10:30') at time zone 'Asia/Singapore', null) then
    raise exception 'FIXTURE: the named team member is still free at the new time — the trap is not set';
  end if;

  perform pg_temp.as_v695_user(v_owner);
  v_res := public.staff_reschedule_and_confirm_booking_request_v329(
    v_business, v_request, (v_day + time '10:00') at time zone 'Asia/Singapore', null, true);
  perform pg_temp.as_v695_system();
  select request_row.staff_id into v_after
    from public.booking_requests request_row where request_row.id = v_request;
  select appointment.staff_id into v_appt_staff
    from public.appointments appointment
    join public.booking_requests request_row on request_row.appointment_id = appointment.id
   where request_row.id = v_request;
  if v_after is null
     and coalesce(v_res->>'outcome','') = 'applied'
     and v_appt_staff is not null
     and v_appt_staff <> v_staff then
    insert into v695_out values (2,'p_clear_staff => true un-assigns the request, so round-robin books somebody who is actually free','PASS');
  else
    insert into v695_out values (2,'p_clear_staff => true un-assigns the request, so round-robin books somebody who is actually free',
      format('FAIL - request.staff_id=%s outcome=%s appointment.staff_id=%s (asked_for=%s, and they are busy at that time)',
             coalesce(v_after::text,'<null>'), coalesce(v_res->>'outcome','<null>'),
             coalesce(v_appt_staff::text,'<null>'), v_staff));
  end if;

  -- ------------------------------------------------------------------ 3. null alone is "unchanged"
  v_res := public.internal_public_booking_submit(
    v_slug, 'V695 Guest B', 'v695.b@example.com', '+6581000202', v_service,
    1, (v_day + time '12:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v695:t3:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:i3:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:f3:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  v_request := nullif(v_res->>'request_id','')::uuid;
  perform pg_temp.as_v695_user(v_owner);
  -- The FOUR-argument call: still valid, and still means "leave the team member alone".
  v_res := public.staff_reschedule_and_confirm_booking_request_v329(
    v_business, v_request, (v_day + time '12:30') at time zone 'Asia/Singapore', null);
  perform pg_temp.as_v695_system();
  select request_row.staff_id into v_after
    from public.booking_requests request_row where request_row.id = v_request;
  if v_after = v_staff then
    insert into v695_out values (3,'the four-argument call (p_staff null, no flag) still leaves the assignment untouched','PASS');
  else
    insert into v695_out values (3,'the four-argument call (p_staff null, no flag) still leaves the assignment untouched',
      format('FAIL - staff_id=%s expected=%s', coalesce(v_after::text,'<null>'), v_staff));
  end if;

  -- ------------------------------------------------------------------ 4. naming a member assigns
  v_res := public.internal_public_booking_submit(
    v_slug, 'V695 Guest C', 'v695.c@example.com', '+6581000203', v_service,
    1, (v_day + time '14:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v695:t4:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:i4:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:f4:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  v_request := nullif(v_res->>'request_id','')::uuid;
  perform pg_temp.as_v695_user(v_owner);
  v_res := public.staff_reschedule_and_confirm_booking_request_v329(
    v_business, v_request, (v_day + time '14:30') at time zone 'Asia/Singapore', v_other, false);
  perform pg_temp.as_v695_system();
  select request_row.staff_id into v_after
    from public.booking_requests request_row where request_row.id = v_request;
  if v_after = v_other then
    insert into v695_out values (4,'naming a different team member still re-assigns the request to them','PASS');
  else
    insert into v695_out values (4,'naming a different team member still re-assigns the request to them',
      format('FAIL - staff_id=%s expected=%s', coalesce(v_after::text,'<null>'), v_other));
  end if;

  -- ------------------------------------------------------------------ 5. both at once is refused
  v_res := public.internal_public_booking_submit(
    v_slug, 'V695 Guest D', 'v695.d@example.com', '+6581000204', v_service,
    1, (v_day + time '16:00') at time zone 'Asia/Singapore', null, null, false,
    encode(sha256(convert_to('v695:t5:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:i5:' || v_business::text, 'UTF8')), 'hex'),
    encode(sha256(convert_to('v695:f5:' || v_business::text, 'UTF8')), 'hex'),
    null, v_staff, v_branch);
  v_request := nullif(v_res->>'request_id','')::uuid;
  perform pg_temp.as_v695_user(v_owner);
  v_err := null;
  begin
    perform public.staff_reschedule_and_confirm_booking_request_v329(
      v_business, v_request, (v_day + time '16:30') at time zone 'Asia/Singapore', v_other, true);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v695_system();
  select request_row.staff_id into v_after
    from public.booking_requests request_row where request_row.id = v_request;
  if v_err = '22023' and v_after = v_staff then
    insert into v695_out values (5,'naming a member AND clearing is refused (22023), and the request is untouched','PASS');
  else
    insert into v695_out values (5,'naming a member AND clearing is refused (22023), and the request is untouched',
      format('FAIL - sqlstate=%s staff_id=%s', coalesce(v_err,'<none>'), coalesce(v_after::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 6. the guard still guards
  perform pg_temp.as_v695_user(v_outsider);
  v_err := null;
  begin
    perform public.staff_reschedule_and_confirm_booking_request_v329(
      v_business, v_request, (v_day + time '17:00') at time zone 'Asia/Singapore', null, true);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v695_system();
  select request_row.staff_id into v_after
    from public.booking_requests request_row where request_row.id = v_request;
  if v_err = '42501' and v_after = v_staff then
    insert into v695_out values (6,'somebody who is not a member of the business is still refused (42501)','PASS');
  else
    insert into v695_out values (6,'somebody who is not a member of the business is still refused (42501)',
      format('FAIL - sqlstate=%s staff_id=%s', coalesce(v_err,'<none>'), coalesce(v_after::text,'<null>')));
  end if;
end
$v695_test$;

select seq, step, outcome from v695_out order by seq;

do $v695_gate$
declare v_bad integer; v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v695_out;
  if v_all <> 6 then
    raise exception 'nestly_v695: % of 6 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v695: % assertion(s) FAILED: %', v_bad,
      (select string_agg(seq || ' ' || step || ' => ' || outcome, ' || ')
         from v695_out where outcome not like 'PASS%');
  end if;
end
$v695_gate$;

rollback;
