-- Rollback-only acceptance for nestly_v581 — the short-notice reminder lane,
-- the registry approval gate on the appointment lane, and telling the customer
-- their appointment moved.
-- Run: supabase db query --linked -f db/tests/v581_short_notice_and_reschedule.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Fixture: production tenant Cubbly (8492e8d6-8888-4383-ada0-7e1ed69f0caa). The
-- whatsapp_appointment_notification capability is set unlimited, the four owner
-- automation switches (v583, live on top of v581 today) are all turned on so
-- this suite measures the v581 gates and not a later switch, and the two new
-- templates (appointment_reminder_short, appointment_updated) are temporarily
-- flipped to 'approved' — all INSIDE the transaction. Appointment age is
-- simulated with a direct `update appointments set created_at = ...`. Every
-- assertion below is EXECUTED against the real, live functions; nothing is
-- committed.
--
--   01  six bookings -> six confirmations (the AAFTER INSERT trigger, unmoved
--       by this migration)
--   02  a 23-hour-out booking IS reminded by the existing 23-25h lane
--   03  a booking 2h out, created 10h ago, gets exactly one
--       appointment_reminder_short
--   04  a booking 2h out created JUST NOW gets no reminder — the
--       created_at <= now()-45min guard
--   05  a 90-minute-out booking gets its confirmation and nothing else
--   06  a 12-hour-out booking gets nothing from either window yet
--   07  running the sweep again enqueues nothing new (duplicate >= 1)
--   08  an appointment driven through BOTH windows (24h lane, then moved into
--       the short window) ends with exactly ONE live reminder
--   09  two real reschedules (starts_at actually changes) queue two
--       appointment_updated notices
--   10  re-saving the same starts_at, and an internal note edit that never
--       touches starts_at, queue nothing
--   11  cancelling an appointment after it was rescheduled leaves nothing of
--       its claimable — the v580 claim suppresses it by name
--   12  a 'draft' registry template refuses with reason 'template_not_approved'
--   13  net.http_request_queue is unchanged throughout
--
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _f(label text primary key, id uuid) on commit drop;

create temp table _base(k text primary key, n bigint) on commit drop;
insert into _base values
  ('http_queue', (select count(*) from net.http_request_queue));

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
do $setup$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid;
  v_service uuid;
begin
  update app.platform_feature_flags set enabled = true
   where feature_key = 'whatsapp_outbound';

  -- The owner's v583 switches sit on top of v581 today; all four ON so this
  -- suite measures the v581 gates (registry approval, the short window, the
  -- reschedule trigger) rather than a later per-lane switch.
  update public.businesses
     set wa_confirmation_enabled = true,
         wa_reminder_24h_enabled = true,
         wa_reminder_short_enabled = true,
         wa_bringback_enabled = true
   where id = v_biz;

  insert into public.business_capability_grants_v518(
    business_id, capability_key, enabled, limit_count, limit_period, note)
  values (v_biz, 'whatsapp_appointment_notification', true, null, 'month', 'v581 suite arm')
  on conflict (business_id, capability_key) do update
    set enabled = true, limit_count = null, updated_at = now();

  -- The two new v581 kinds ship 'draft'. Approved here so every check but 12
  -- measures the WINDOW/TRIGGER logic and not the approval gate; 12 flips one
  -- back to prove the gate still bites.
  update public.whatsapp_template_registry_v551
     set status = 'approved'
   where template_key in ('appointment_reminder_short', 'appointment_updated');

  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (v_biz, 'v581 suite client', '+65 8555 8101', true)
  returning id into v_client;
  insert into _f values ('client', v_client);

  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz, 'v581 suite service', 5000, 30, true)
  returning id into v_service;
  insert into _f values ('service', v_service);
end
$setup$;

-- ---------------------------------------------------------------------------
-- 01 six bookings -> six confirmations
-- ---------------------------------------------------------------------------
do $confirmations$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid := (select id from _f where label = 'client');
  v_service uuid := (select id from _f where label = 'service');
  v_id uuid;
  i int;
begin
  for i in 1..6 loop
    insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
    values (v_biz, v_client, v_service,
            now() + make_interval(days => 3, hours => i),
            now() + make_interval(days => 3, hours => i) + interval '30 min',
            'booked')
    returning id into v_id;
    insert into _f values ('conf'||i, v_id);
  end loop;

  insert into _r
  select '01 six bookings produced six confirmations',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label like 'conf%' and s.kind = 'appointment_confirmation'
                 and s.status = 'queued') = 6
         then 'PASS the AFTER INSERT trigger is unmoved by this migration'
         else 'FAIL '||coalesce((select count(*)::text from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label like 'conf%' and s.kind = 'appointment_confirmation'),'0')
              ||' confirmations for 6 bookings' end;
end
$confirmations$;

-- ---------------------------------------------------------------------------
-- Appointments for the window checks (02, 03, 04, 05, 06, 08)
-- ---------------------------------------------------------------------------
do $windows$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid := (select id from _f where label = 'client');
  v_service uuid := (select id from _f where label = 'service');
  v_id uuid;
begin
  -- 23h out: inside the 23-25h reminder lane.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '23 hours 30 minutes',
          now() + interval '24 hours', 'booked')
  returning id into v_id;
  insert into _f values ('appt_23h', v_id);

  -- 2h out, will be backdated to look 10h old (passes the 45-minute guard).
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '2 hours',
          now() + interval '2 hours 30 minutes', 'booked')
  returning id into v_id;
  insert into _f values ('appt_short_ok', v_id);
  update public.appointments set created_at = now() - interval '10 hours' where id = v_id;

  -- 2h out, booked just now: must NOT be reminded.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '2 hours 5 minutes',
          now() + interval '2 hours 35 minutes', 'booked')
  returning id into v_id;
  insert into _f values ('appt_short_noage', v_id);

  -- 90 minutes out, booked just now: confirmation only.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '90 minutes',
          now() + interval '2 hours', 'booked')
  returning id into v_id;
  insert into _f values ('appt_90min', v_id);

  -- 12h out: outside both windows entirely.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '12 hours',
          now() + interval '12 hours 30 minutes', 'booked')
  returning id into v_id;
  insert into _f values ('appt_12h', v_id);

  -- Starts 24h out, same as appt_23h's lane, so the first sweep reminds it via
  -- the 24h pass; it is later dragged into the short window for check 08.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '24 hours',
          now() + interval '24 hours 30 minutes', 'booked')
  returning id into v_id;
  insert into _f values ('appt_both', v_id);
end
$windows$;

-- ---------------------------------------------------------------------------
-- First sweep: exercises both passes over all the window fixtures at once.
-- ---------------------------------------------------------------------------
do $sweep1$
declare
  v_result jsonb;
begin
  v_result := app.run_whatsapp_reminder_sweep_v557(500);

  insert into _r
  select '02 a 23-hour-out booking IS reminded by the 23-25h lane',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_23h' and s.kind = 'appointment_reminder'
                 and s.status = 'queued') = 1
         then 'PASS'
         else 'FAIL sweep result '||v_result::text end;

  insert into _r
  select '03 a 2h-out booking created 10h ago gets exactly one short-notice reminder',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_short_ok' and s.kind = 'appointment_reminder_short') = 1
         then 'PASS'
         else 'FAIL sweep result '||v_result::text end;

  insert into _r
  select '04 a 2h-out booking made JUST NOW gets no reminder (45-minute guard)',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_short_noage'
                 and s.kind in ('appointment_reminder','appointment_reminder_short')) = 0
         then 'PASS the created_at <= now()-45min guard held'
         else 'FAIL a fresh booking was reminded before it was old enough' end;

  insert into _r
  select '05 a 90-minute-out booking gets confirmation only',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_90min' and s.kind = 'appointment_confirmation') = 1
          and (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_90min'
                 and s.kind in ('appointment_reminder','appointment_reminder_short')) = 0
         then 'PASS a reminder minutes after the confirmation is noise, not service'
         else 'FAIL '||coalesce((select string_agg(s.kind||'/'||s.status, ' ')
                from public.whatsapp_template_sends_v557 s join _f f on f.id = s.appointment_id
               where f.label = 'appt_90min'),'<none>') end;

  insert into _r
  select '06 a 12-hour-out booking gets nothing from either window yet',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_12h'
                 and s.kind in ('appointment_reminder','appointment_reminder_short')) = 0
         then 'PASS'
         else 'FAIL a 12h-out booking was reminded before either window opened' end;

  insert into _r
  select '02b appt_both was reminded by the 24h lane on the first pass',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label = 'appt_both' and s.kind = 'appointment_reminder'
                 and s.status = 'queued') = 1
         then 'PASS'
         else 'FAIL sweep result '||v_result::text end;
end
$sweep1$;

-- ---------------------------------------------------------------------------
-- Drag appt_both into the short window, then sweep again: covers 07 and 08.
-- ---------------------------------------------------------------------------
do $sweep2$
declare
  v_id uuid := (select id from _f where label = 'appt_both');
  v_before_count bigint;
  v_result jsonb;
begin
  update public.appointments
     set starts_at = now() + interval '2 hours',
         ends_at   = now() + interval '2 hours 30 minutes',
         created_at = now() - interval '10 hours'
   where id = v_id;

  select count(*) into v_before_count from public.whatsapp_template_sends_v557;

  v_result := app.run_whatsapp_reminder_sweep_v557(500);

  insert into _r
  select '07 running the sweep again enqueues nothing new',
    case when (select count(*) from public.whatsapp_template_sends_v557) = v_before_count
          and coalesce((v_result->>'duplicate')::int, 0) >= 1
         then 'PASS row count unchanged, duplicate='||(v_result->>'duplicate')
         else 'FAIL rows before='||v_before_count::text
              ||' after='||(select count(*) from public.whatsapp_template_sends_v557)::text
              ||' result='||v_result::text end;

  insert into _r
  select '08 an appointment driven through both windows ends with exactly one live reminder',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
               where s.appointment_id = v_id
                 and s.kind in ('appointment_reminder','appointment_reminder_short')
                 and s.status in ('queued','processing','sent','delivered','read')) = 1
         then 'PASS the already-reminded guard stopped a second live reminder for the new time'
         else 'FAIL '||coalesce((select string_agg(s.kind||'/'||s.status, ' ')
                from public.whatsapp_template_sends_v557 s where s.appointment_id = v_id
                 and s.kind in ('appointment_reminder','appointment_reminder_short')),'<none>') end;
end
$sweep2$;

-- ---------------------------------------------------------------------------
-- 09 / 10 / 11 reschedule, no-op saves, and cancel-after-reschedule
-- ---------------------------------------------------------------------------
do $reschedule$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid := (select id from _f where label = 'client');
  v_service uuid := (select id from _f where label = 'service');
  v_id uuid;
  v_t1 timestamptz;
  v_t2 timestamptz;
begin
  v_t1 := now() + interval '3 days';
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, v_t1, v_t1 + interval '30 min', 'booked')
  returning id into v_id;
  insert into _f values ('resched', v_id);

  -- Two REAL reschedules: starts_at actually changes each time.
  v_t1 := v_t1 + interval '1 day';
  update public.appointments set starts_at = v_t1, ends_at = v_t1 + interval '30 min'
   where id = v_id;

  v_t2 := v_t1 + interval '1 day';
  update public.appointments set starts_at = v_t2, ends_at = v_t2 + interval '30 min'
   where id = v_id;

  insert into _r
  select '09 two real reschedules queue two appointment_updated notices',
    case when (select count(*) from public.whatsapp_template_sends_v557
                where appointment_id = v_id and kind = 'appointment_updated') = 2
         then 'PASS'
         else 'FAIL '||coalesce((select count(*)::text from public.whatsapp_template_sends_v557
                where appointment_id = v_id and kind = 'appointment_updated'),'0')
              ||' appointment_updated rows for two reschedules' end;

  -- Re-saving the SAME starts_at: the column is in the SET list but unchanged,
  -- so the trigger's WHEN clause (old IS DISTINCT FROM new) must not fire it.
  update public.appointments set starts_at = v_t2, ends_at = v_t2 + interval '30 min'
   where id = v_id;

  -- An internal edit that never touches starts_at at all.
  update public.appointments set source = 'internal-note-edit' where id = v_id;

  insert into _r
  select '10 re-saving the same time, and an internal edit, queue nothing',
    case when (select count(*) from public.whatsapp_template_sends_v557
                where appointment_id = v_id and kind = 'appointment_updated') = 2
         then 'PASS still exactly the two rows from the two real reschedules'
         else 'FAIL '||coalesce((select count(*)::text from public.whatsapp_template_sends_v557
                where appointment_id = v_id and kind = 'appointment_updated'),'0')
              ||' appointment_updated rows after two no-op saves' end;

  -- Cancel-after-reschedule: the v580 claim must find nothing of this
  -- appointment claimable, by name.
  update public.appointments set status = 'cancelled' where id = v_id;

  perform public.internal_whatsapp_claim_template_sends_v557('v581-suite-worker', 500, 120);

  insert into _r
  select '11 cancel-after-reschedule leaves nothing claimable',
    case when (select count(*) from public.whatsapp_template_sends_v557
                where appointment_id = v_id and status in ('queued','processing')) = 0
          and (select count(*) from public.whatsapp_template_sends_v557
                where appointment_id = v_id and status = 'processing') = 0
          and (select bool_or(last_error_code = 'appointment_cancelled') from public.whatsapp_template_sends_v557
                where appointment_id = v_id and status = 'failed')
         then 'PASS the cancelled appointment''s rows were suppressed by name, none leased'
         else 'FAIL '||coalesce((select string_agg(status||'/'||coalesce(last_error_code,'-'), ' ')
                from public.whatsapp_template_sends_v557 where appointment_id = v_id),'<none>') end;
end
$reschedule$;

-- ---------------------------------------------------------------------------
-- 12 a 'draft' registry template refuses with reason 'template_not_approved'
-- ---------------------------------------------------------------------------
do $draft$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_id uuid := (select id from _f where label = 'appt_12h');
  v_result jsonb;
begin
  update public.whatsapp_template_registry_v551
     set status = 'draft'
   where template_key = 'appointment_reminder_short';

  v_result := app.whatsapp_enqueue_appointment_notice_v557(
    v_biz, v_id, 'appointment_reminder_short');

  insert into _r
  select '12 a draft registry template refuses with reason template_not_approved',
    case when v_result->>'status' = 'refused'
          and v_result->>'reason' = 'template_not_approved'
          and v_result->>'template_status' = 'draft'
         then 'PASS the newly added lane is inert until Meta approves it'
         else 'FAIL '||v_result::text end;

  -- Restored so this suite leaves the fixture as it found it (belt and
  -- braces; the whole transaction rolls back regardless).
  update public.whatsapp_template_registry_v551
     set status = 'approved'
   where template_key = 'appointment_reminder_short';
end
$draft$;

-- ---------------------------------------------------------------------------
-- 13 nothing was ever sent
-- ---------------------------------------------------------------------------
insert into _r
select '13 net.http_request_queue is unchanged throughout',
  case when (select count(*) from net.http_request_queue) = (select n from _base where k = 'http_queue')
       then 'PASS every check above ran against real functions with no HTTP fired'
       else 'FAIL net.http_request_queue grew during the suite' end;

select k as check_name, v as result from _r order by k;

rollback;
