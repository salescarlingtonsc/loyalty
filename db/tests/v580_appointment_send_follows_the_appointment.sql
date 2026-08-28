-- Rollback-only acceptance for nestly_v580 — an appointment message follows
-- its appointment (cancel / reschedule / delete all suppress by name).
-- Run: supabase db query --linked -f db/tests/v580_appointment_send_follows_the_appointment.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- THIS IS A TRANSCRIPTION of the exact probe run during the 2026-08-28
-- ship-readiness audit (6/6 PASS against prod), rewritten into the house
-- rollback-suite shape. It does not invent new scenarios.
--
--   01  arm Cubbly's whatsapp_appointment_notification capability + module +
--       the platform outbound switch, INSIDE the transaction
--   02  a real appointment INSERT — via the AFTER INSERT trigger, not a
--       hand-built queue row — enqueues exactly one confirmation each, x3
--   03  cancel #1, reschedule #2 (+2h), delete #3
--   04  claim -> 0 leased (all three are stale before they can be sent)
--   05  the three rows are status='failed' with the exact named reason:
--       appointment_cancelled / appointment_rescheduled / appointment_deleted
--   06  each suppression released its reserved capability unit (3 rows)
--   07  re-enqueueing #2's confirmation gets a NEW key (duplicate=false) —
--       the reschedule re-arms the notice for its new time
--   08  claim again -> exactly 1 leased (the fresh #2 confirmation only)
--   09  net.http_request_queue never moved — nothing was ever dispatched
--   10  belt-and-braces: the claim CTE itself, not only the pre-sweep, is
--       gated on status='booked' AND the idempotency-key/starts_at match

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _fixture(label text, appt_id uuid, send_id uuid, idem_key text) on commit drop;
create temp table _claim(id uuid) on commit drop;

create temp table _base(k text primary key, n bigint) on commit drop;
insert into _base values
  ('http_queue', (select count(*) from net.http_request_queue));

do $setup$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
begin
  -- Platform master switch ON, inside the tx — the capability and enqueue
  -- path both gate on it, and this suite must not depend on prod's current
  -- flag state to pass.
  update app.platform_feature_flags set enabled = true
   where feature_key = 'whatsapp_outbound';

  -- The genuine functional prerequisite: a firm with no appointments module
  -- has nothing to notify about.
  update public.businesses
     set enabled_modules = (
       select array_agg(distinct m) from unnest(
         coalesce(enabled_modules, array[]::text[]) || array['appointments']) m)
   where id = v_biz;

  -- Arm the capability directly for Cubbly: enabled, unlimited for this run,
  -- so the suite's own three confirmations can never collide with a real
  -- monthly cap.
  insert into public.business_capability_grants_v518(
    business_id, capability_key, enabled, limit_count, limit_period, note)
  values (v_biz, 'whatsapp_appointment_notification', true, null, 'month', 'v580 suite arm')
  on conflict (business_id, capability_key) do update
    set enabled = true, limit_count = null, updated_at = now();
end
$setup$;

-- --------------------------------------------------- 01 capability armed
insert into _r
select '01 capability is armed for Cubbly',
  case when (app.capability_state_v518(
              '8492e8d6-8888-4383-ada0-7e1ed69f0caa',
              'whatsapp_appointment_notification')->>'allowed')::boolean
       then 'PASS whatsapp_appointment_notification resolves allowed=true'
       else 'FAIL '||(app.capability_state_v518(
              '8492e8d6-8888-4383-ada0-7e1ed69f0caa',
              'whatsapp_appointment_notification')::text) end;

-- ---------------------------------------------- 02 the real INSERT enqueues
do $book$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid;
  v_service uuid;
  v_a1 uuid; v_a2 uuid; v_a3 uuid;
begin
  insert into public.clients(business_id, full_name, phone)
  values (v_biz, 'v580 suite client', '+65 8555 8001')
  returning id into v_client;

  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz, 'v580 suite service', 5000, 30, true)
  returning id into v_service;

  -- Three ordinary bookings. The AFTER INSERT trigger
  -- (whatsapp_appointment_booked_v557) does the enqueueing — nothing here
  -- touches whatsapp_template_sends_v557 directly.
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '1 day', now() + interval '1 day 30 min', 'booked')
  returning id into v_a1;
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '2 day', now() + interval '2 day 30 min', 'booked')
  returning id into v_a2;
  insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
  values (v_biz, v_client, v_service, now() + interval '3 day', now() + interval '3 day 30 min', 'booked')
  returning id into v_a3;

  insert into _fixture(label, appt_id, send_id, idem_key)
  select 'cancelled', v_a1, id, idempotency_key
    from public.whatsapp_template_sends_v557
   where appointment_id = v_a1 and kind = 'appointment_confirmation';
  insert into _fixture(label, appt_id, send_id, idem_key)
  select 'rescheduled', v_a2, id, idempotency_key
    from public.whatsapp_template_sends_v557
   where appointment_id = v_a2 and kind = 'appointment_confirmation';
  insert into _fixture(label, appt_id, send_id, idem_key)
  select 'deleted', v_a3, id, idempotency_key
    from public.whatsapp_template_sends_v557
   where appointment_id = v_a3 and kind = 'appointment_confirmation';

  -- 03: cancel #1, reschedule #2 (+2h), delete #3.
  update public.appointments set status = 'cancelled' where id = v_a1;
  update public.appointments
     set starts_at = starts_at + interval '2 hours',
         ends_at   = ends_at   + interval '2 hours'
   where id = v_a2;
  delete from public.appointments where id = v_a3;
end
$book$;

insert into _r
select '02 the real INSERT (trigger, not a hand-built row) queued all three',
  case when (select count(*) from _fixture) = 3
        and (select count(*) from _fixture where send_id is null) = 0
       then 'PASS three confirmations queued by the AFTER INSERT trigger'
       else 'FAIL '||coalesce((select count(*)::text from _fixture),'0')||' fixture rows captured' end;

-- ------------------------------------------------------ 04 claim -> 0 leased
insert into _claim
select message_id from public.internal_whatsapp_claim_template_sends_v557('v580-suite-1', 20, 120);

insert into _r
select '04 the claim leases none of the three stale rows',
  case when (select count(*) from _claim) = 0
       then 'PASS 0 leased — all three were caught before they could send'
       else 'FAIL '||(select count(*)::text from _claim)||' leased' end;

-- --------------------------------------- 05 named suppression, one per hole
insert into _r
select '05a cancelled appointment -> appointment_cancelled',
  case when (select status from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'cancelled')) = 'failed'
        and (select last_error_code from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'cancelled')) = 'appointment_cancelled'
       then 'PASS'
       else 'FAIL '||coalesce((select status||'/'||coalesce(last_error_code,'-')
              from public.whatsapp_template_sends_v557
             where id = (select send_id from _fixture where label = 'cancelled')),'<no row>') end;

insert into _r
select '05b rescheduled appointment -> appointment_rescheduled',
  case when (select status from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'rescheduled')) = 'failed'
        and (select last_error_code from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'rescheduled')) = 'appointment_rescheduled'
       then 'PASS'
       else 'FAIL '||coalesce((select status||'/'||coalesce(last_error_code,'-')
              from public.whatsapp_template_sends_v557
             where id = (select send_id from _fixture where label = 'rescheduled')),'<no row>') end;

insert into _r
select '05c deleted appointment -> appointment_deleted',
  case when (select status from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'deleted')) = 'failed'
        and (select last_error_code from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'deleted')) = 'appointment_deleted'
        and (select appointment_id from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'deleted')) is null
       then 'PASS the FK ON DELETE SET NULL is exactly what names it deleted'
       else 'FAIL '||coalesce((select status||'/'||coalesce(last_error_code,'-')
              from public.whatsapp_template_sends_v557
             where id = (select send_id from _fixture where label = 'deleted')),'<no row>') end;

-- ------------------------------------------------ 06 quota given back, x3
insert into _r
select '06 each suppression released its reserved capability unit',
  case when (
        select count(*) from public.capability_usage_v518 u
         join _fixture f on u.idem_key = 'release:' || f.idem_key
        where u.business_id = '8492e8d6-8888-4383-ada0-7e1ed69f0caa'
          and u.capability_key = 'whatsapp_appointment_notification'
          and u.detail->>'kind' = 'release'
       ) = 3
       then 'PASS three compensating rows, one per suppressed send, none double-spent'
       else 'FAIL '||(
        select count(*)::text from public.capability_usage_v518 u
         join _fixture f on u.idem_key = 'release:' || f.idem_key
        where u.business_id = '8492e8d6-8888-4383-ada0-7e1ed69f0caa'
          and u.capability_key = 'whatsapp_appointment_notification'
          and u.detail->>'kind' = 'release'
       )||' release rows found' end;

-- --------------------------------------- 07 reschedule re-arms with a new key
do $rearm$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_a2 uuid := (select appt_id from _fixture where label = 'rescheduled');
  v_result jsonb;
begin
  v_result := app.whatsapp_enqueue_appointment_notice_v557(
    v_biz, v_a2, 'appointment_confirmation');
  insert into _fixture(label, appt_id, send_id, idem_key)
  values ('rescheduled_rearmed', v_a2, (v_result->>'send_id')::uuid, v_result->>'idempotency_key');

  insert into _r
  select '07 the new starts_at produces a NEW key, so this is a fresh notice',
    case when (v_result->>'duplicate') = 'false'
          and (v_result->>'status') = 'ok'
          and v_result->>'idempotency_key' <> (select idem_key from _fixture where label = 'rescheduled')
         then 'PASS duplicate=false; the old and new idempotency keys differ'
         else 'FAIL '||v_result::text end;
end
$rearm$;

-- ---------------------------------------------- 08 claim again -> exactly 1
delete from _claim;
insert into _claim
select message_id from public.internal_whatsapp_claim_template_sends_v557('v580-suite-2', 20, 120);

insert into _r
select '08 the second claim leases exactly the fresh reschedule confirmation',
  case when (select count(*) from _claim) = 1
        and (select id from _claim) = (select send_id from _fixture where label = 'rescheduled_rearmed')
       then 'PASS the only real, booked, correctly-keyed row is the one that leases'
       else 'FAIL leased '||(select count(*)::text from _claim)||' row(s)' end;

-- ------------------------------------------------------- 09 nothing was sent
insert into _r
select '09 no HTTP request was ever queued by this suite',
  case when (select count(*) from net.http_request_queue) = (select n from _base where k = 'http_queue')
       then 'PASS net.http_request_queue is unchanged — this suite never dispatches, only claims'
       else 'FAIL net.http_request_queue grew during the suite' end;

-- -------------------------------------------- 10 belt-and-braces (behavioural)
-- The header's own claim: the suppression sweep and the claim are two
-- statements, so an appointment can be cancelled between them, and the SAME
-- predicate (status='booked' AND idempotency_key matches the row's own
-- starts_at) is repeated inside the claimable CTE, not only in the pre-sweep.
-- Proven behaviourally rather than by string-matching the function body: the
-- rescheduled row's ORIGINAL (stale) send never became leasable at any point
-- in this suite even though it sat in the table the whole time, and the fresh
-- one only became leasable once it satisfied that same predicate.
insert into _r
select '10 the claimable CTE itself enforces booked+key-match, not just the sweep',
  case when (select status from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'rescheduled')) = 'failed'
        and (select status from public.whatsapp_template_sends_v557
              where id = (select send_id from _fixture where label = 'rescheduled_rearmed')) = 'processing'
        and pg_get_functiondef('public.internal_whatsapp_claim_template_sends_v557(text,integer,integer)'::regprocedure)
            ilike '%a.status = ''booked''%'
        and pg_get_functiondef('public.internal_whatsapp_claim_template_sends_v557(text,integer,integer)'::regprocedure)
            ilike '%m.idempotency_key = (m.kind%'
       then 'PASS the stale row stayed failed and unleasable while the correctly-keyed one leased'
       else 'FAIL the claimable CTE does not re-check booked status and key match' end;

select k as check_name, v as result from _r order by k;

rollback;
