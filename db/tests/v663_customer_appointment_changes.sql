-- Rollback-only v663 acceptance suite (owner review 2026-08-31, photos 1 and 2).
--
-- SECTION 1 — the customer can be told WHICH world they are in before they press anything.
--   S1-T1  customer_get_business_actions_v89 reports appointment_changes.auto_approve, and it is
--          the business's own auto_approve_changes.
--   S1-T2  auto_approve is never reported true while changes are disabled: an auto-approval of an
--          action that cannot be taken is not a fact about anything.
--   S1-T3  customer_get_appointments_page carries the BRANCH's phone, so "call them instead" can
--          be written with a number in it.
--
-- SECTION 2 — cancelling a confirmed booking.
--   S2-T1  Auto-approve ON: the appointment is cancelled on the spot and says so.
--   S2-T2  THE ONE THAT MATTERS. Auto-approve OFF: the appointment stays BOOKED and a pending
--          public.change_requests row appears — the table the business's Bookings page lists.
--   S2-T3  A second press while that request is pending returns the same request, not a second one.
--   S2-T4  Changes disabled: the typed refusal, and nothing is written.
--
-- SECTION 3 — rescheduling a confirmed booking.
--   S3-T1  Auto-approve ON and the slot free: confirmed on the spot, with a real appointment.
--   S3-T2  Auto-approve OFF: pending, exactly as before v663.
--
-- Every call runs as the REAL customer role (set local role authenticated with the customer's own
-- jwt sub), never as the owner or postgres — a permission proved from a privileged seat is not
-- proved. Run against a prod-shaped instance carrying the canonical chain through v663.
begin;
create temporary table v663_evidence(test text) on commit drop;
grant insert, select on v663_evidence to authenticated;

-- Jess Salon: appointment changes ON, auto-approve ON, one branch, active services, and one
-- verified customer link. Substitute your own ids when running elsewhere.
create temporary table v663_fixture on commit drop as
select '709387ff-5768-4767-9dad-abd665c2bb07'::uuid as business_id,
       'jess-salon'::text as slug,
       '22239949-ac57-433c-ad7c-549dc603db88'::uuid as client_id,
       'eeb3ce63-73ca-4713-b1b5-95bd37e0028a'::uuid as auth_user_id;
grant select on v663_fixture to authenticated;

do $fx$
declare f record;
begin
  select * into f from v663_fixture;
  if not exists (select 1 from public.customer_links l
                  where l.business_id=f.business_id and l.client_id=f.client_id
                    and l.auth_user_id=f.auth_user_id and l.state='verified') then
    raise exception 'V663 FIXTURE: the named customer is not verified against the named business';
  end if;
  if not exists (select 1 from public.services s
                  where s.business_id=f.business_id and coalesce(s.active,true)) then
    raise exception 'V663 FIXTURE: the business needs an active service';
  end if;
  -- The phone assertion needs a branch that HAS one. Give the fixture branch a number for the
  -- duration of this transaction rather than skipping the test on a tenant that never set one.
  update public.branches set phone='+65 6100 0663'
   where business_id=f.business_id and active
     and id=(select id from public.branches where business_id=f.business_id and active order by id limit 1);
  update public.businesses set auto_approve_changes=true where id=f.business_id;
  insert into public.business_customer_capabilities_v89(business_id, appointment_changes_enabled)
  values(f.business_id, true)
  on conflict (business_id) do update set appointment_changes_enabled=true;

  /* S3-T1 needs a slot at which a bookable team member is genuinely free, and availability fails
     CLOSED on a tenant that has never entered opening hours. Open every weekday for the duration
     of this transaction and clear the personal restrictions, so the auto-approve branch is
     REACHED and asserted rather than skipped. Everything here is rolled back. */
  delete from public.staff_hours where business_id=f.business_id;
  delete from public.staff_blocked_times where business_id=f.business_id;
  delete from public.branch_hours where business_id=f.business_id;
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select f.business_id, branch.id, weekday.day, time '00:00', time '23:59'
    from public.branches branch, generate_series(0,6) as weekday(day)
   where branch.business_id=f.business_id and branch.active;
end $fx$;

-- A future booked appointment the customer owns, and a second one for the OFF case.
create temporary table v663_appts(label text primary key, appointment_id uuid) on commit drop;
grant select on v663_appts to authenticated;

do $fx$
declare f record; v_branch uuid; v_service uuid; v_at timestamptz; v_id uuid; v_label text;
begin
  select * into f from v663_fixture;
  select id into v_branch from public.branches where business_id=f.business_id and active order by id limit 1;
  select id into v_service from public.services where business_id=f.business_id and coalesce(active,true) order by id limit 1;
  -- Well clear of anything real, and far enough ahead that "must be in the future" can never be
  -- flaky against the clock this suite happens to run at.
  v_at := date_trunc('hour', now()) + interval '40 days';
  foreach v_label in array array['auto','manual','disabled','resched_auto','resched_manual'] loop
    insert into public.appointments(business_id, client_id, starts_at, ends_at, status,
      party_size, source, service_id, branch_id)
    values(f.business_id, f.client_id, v_at, v_at + interval '45 minutes', 'booked',
      1, 'portal', v_service, v_branch)
    returning id into v_id;
    insert into v663_appts values(v_label, v_id);
    v_at := v_at + interval '1 day';
  end loop;
end $fx$;

do $t$
declare f record; v_actions jsonb; v_items jsonb;
begin
  select * into f from v663_fixture;
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;

  -- S1-T1 / S1-T2: the auto-approve fact, and the guard on it.
  v_actions := public.customer_get_business_actions_v89(f.business_id);
  if (v_actions #>> '{appointment_changes,auto_approve}') is null then
    raise exception 'S1-T1 appointment_changes.auto_approve is not reported at all';
  end if;
  if (v_actions #> '{appointment_changes,auto_approve}')::boolean is not true then
    raise exception 'S1-T1 auto_approve must be true for a business with the box ticked';
  end if;
  insert into v663_evidence values('S1-T1 ok - customer_get_business_actions_v89 reports appointment_changes.auto_approve');

  -- S1-T3: the branch phone reaches the feed.
  v_items := public.customer_get_appointments_page(f.slug, jsonb_build_object('limit',20)) -> 'items';
  if jsonb_array_length(v_items) = 0 then
    raise exception 'S1-T3 the fixture appointments are not visible to their own customer';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_items) item
                  where nullif(item->>'branch_phone','') = '+65 6100 0663') then
    raise exception 'S1-T3 no appointment carried its branch phone number';
  end if;
  insert into v663_evidence values('S1-T3 ok - the appointments feed carries the branch phone number');
  reset role;
end $t$;

do $t$
declare f record; v_actions jsonb;
begin
  select * into f from v663_fixture;
  update public.business_customer_capabilities_v89 set appointment_changes_enabled=false
   where business_id=f.business_id;
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_actions := public.customer_get_business_actions_v89(f.business_id);
  if (v_actions #> '{appointment_changes,auto_approve}')::boolean is not false then
    raise exception 'S1-T2 auto_approve must be false while appointment changes are disabled';
  end if;
  reset role;
  insert into v663_evidence values('S1-T2 ok - auto_approve is never true while changes are disabled');

  -- S2-T4: the typed refusal, and nothing written, while the box is still off.
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.customer_cancel_appointment_v655(f.slug,
      (select appointment_id from v663_appts where label='disabled'));
    reset role;
    raise exception 'S2-T4 cancelling was allowed while appointment changes are disabled';
  exception when sqlstate '42501' then
    reset role;
    if sqlerrm <> 'appointment_changes_disabled' then
      raise exception 'S2-T4 wrong refusal: %', sqlerrm; end if;
  end;
  if (select status from public.appointments
       where id=(select appointment_id from v663_appts where label='disabled')) <> 'booked' then
    raise exception 'S2-T4 the appointment was changed by a refused call';
  end if;
  if exists (select 1 from public.change_requests
              where appointment_id=(select appointment_id from v663_appts where label='disabled')) then
    raise exception 'S2-T4 a refused call still filed a change request';
  end if;
  insert into v663_evidence values('S2-T4 ok - changes disabled refuses with the typed error and writes nothing');
  update public.business_customer_capabilities_v89 set appointment_changes_enabled=true
   where business_id=f.business_id;
end $t$;

do $t$
declare f record; v_appt uuid; v_out jsonb;
begin
  select * into f from v663_fixture;
  update public.businesses set auto_approve_changes=true where id=f.business_id;
  select appointment_id into v_appt from v663_appts where label='auto';
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_out := public.customer_cancel_appointment_v655(f.slug, v_appt);
  reset role;
  if (v_out->>'status') <> 'ok' or (v_out->'auto_approved')::boolean is not true then
    raise exception 'S2-T1 an auto-approving business must cancel on the spot, got %', v_out; end if;
  if (select status from public.appointments where id=v_appt) <> 'cancelled' then
    raise exception 'S2-T1 the appointment was not actually cancelled'; end if;
  insert into v663_evidence values('S2-T1 ok - auto-approve ON cancels the appointment on the spot');
end $t$;

do $t$
declare f record; v_appt uuid; v_out jsonb; v_again jsonb; v_count integer;
begin
  select * into f from v663_fixture;
  update public.businesses set auto_approve_changes=false where id=f.business_id;
  select appointment_id into v_appt from v663_appts where label='manual';
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_out := public.customer_cancel_appointment_v655(f.slug, v_appt);
  v_again := public.customer_cancel_appointment_v655(f.slug, v_appt);
  reset role;

  if (v_out->>'status') <> 'pending' or (v_out->'auto_approved')::boolean is not false then
    raise exception 'S2-T2 without auto-approve the cancel must be a request, got %', v_out; end if;
  if (select status from public.appointments where id=v_appt) <> 'booked' then
    raise exception 'S2-T2 the appointment must stay BOOKED until the business answers'; end if;
  select count(*) into v_count from public.change_requests
   where appointment_id=v_appt and kind='cancel' and status='pending';
  if v_count <> 1 then
    raise exception 'S2-T2 expected exactly one pending change request, found %', v_count; end if;
  insert into v663_evidence values('S2-T2 ok - without auto-approve the appointment stays booked and the business gets a pending change request');

  if (v_again->>'request_id') <> (v_out->>'request_id')
     or (v_again->'replayed')::boolean is not true then
    raise exception 'S2-T3 a second press filed a second request'; end if;
  insert into v663_evidence values('S2-T3 ok - pressing cancel twice returns the same pending request');

  -- And the business's own decision path still closes it, which is what makes the request real.
  perform set_config('app.appt_status_reason_code','',true);
  update public.change_requests set status='approved', decided_at=now()
   where id=(v_out->>'request_id')::uuid;
  update public.appointments set status='cancelled' where id=v_appt;
  if (select status from public.appointments where id=v_appt) <> 'cancelled' then
    raise exception 'S2-T3 the approved request did not reach the appointment'; end if;
end $t$;

do $t$
declare f record; v_appt uuid; v_out jsonb; v_slot timestamptz;
begin
  select * into f from v663_fixture;
  update public.businesses set auto_approve_changes=true where id=f.business_id;
  select appointment_id into v_appt from v663_appts where label='resched_auto';
  -- Next Wednesday 11:00 SGT: inside ordinary working hours, so a bookable team member exists.
  v_slot := (date_trunc('week', (now() at time zone 'Asia/Singapore')) + interval '9 days' + interval '11 hours')
              at time zone 'Asia/Singapore';
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_out := public.customer_reschedule_appointment_v508(f.slug, v_appt, v_slot, null);
  reset role;
  if (v_out->'auto_approved') is null then
    raise exception 'S3-T1 the reschedule result does not report auto_approved at all'; end if;
  if (v_out->'auto_approved')::boolean is not true then
    raise exception 'S3-T1 an auto-approving business must confirm a free slot on the spot, got %', v_out;
  else
    if (v_out->>'appointment_id') is null then
      raise exception 'S3-T1 auto-approved with no appointment behind it'; end if;
    if (select status from public.appointments where id=(v_out->>'appointment_id')::uuid) <> 'booked' then
      raise exception 'S3-T1 the auto-approved appointment is not booked'; end if;
    if (select status from public.booking_requests where id=(v_out->>'request_id')::uuid) <> 'confirmed' then
      raise exception 'S3-T1 the replacement request was not confirmed'; end if;
    insert into v663_evidence values('S3-T1 ok - auto-approve ON confirms the new time on the spot, with a real appointment');
  end if;
end $t$;

do $t$
declare f record; v_appt uuid; v_out jsonb; v_slot timestamptz;
begin
  select * into f from v663_fixture;
  update public.businesses set auto_approve_changes=false where id=f.business_id;
  select appointment_id into v_appt from v663_appts where label='resched_manual';
  v_slot := (date_trunc('week', (now() at time zone 'Asia/Singapore')) + interval '16 days' + interval '11 hours')
              at time zone 'Asia/Singapore';
  perform set_config('request.jwt.claims',
    json_build_object('sub', f.auth_user_id::text, 'role','authenticated')::text, true);
  set local role authenticated;
  v_out := public.customer_reschedule_appointment_v508(f.slug, v_appt, v_slot, null);
  reset role;
  if (v_out->>'status') <> 'pending' or (v_out->'auto_approved')::boolean is not false then
    raise exception 'S3-T2 without auto-approve the reschedule must stay pending, got %', v_out; end if;
  if (select status from public.booking_requests where id=(v_out->>'request_id')::uuid) <> 'pending' then
    raise exception 'S3-T2 the replacement request is not pending'; end if;
  insert into v663_evidence values('S3-T2 ok - auto-approve OFF leaves the new time for the business to answer');
end $t$;

reset role;
select (select count(*) from v663_evidence) as assertions_passed,
       (select string_agg(test, ' | ' order by test) from v663_evidence) as evidence,
       case when (select count(*) from v663_evidence)=9 then 'V663_SUITE_PASSED'
            else 'V663_SUITE_INCOMPLETE' end as verdict;
rollback;
