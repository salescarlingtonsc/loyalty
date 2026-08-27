-- Rollback-only acceptance for nestly_v557 — C7 appointment notifications.
-- Run: supabase db query --linked -f db/tests/v557_whatsapp_appointment_notifications.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  SURFACE: the queue has RLS with ZERO policies and no browser-role
--       grants; the internal claim/report RPCs are service_role only; the
--       superadmin reader is the one thing 'authenticated' may call
--   02  GATE 1: master flag off -> refused 'outbound_not_enabled', nothing queued
--   03  GATE 2: flag on but no per-firm capability -> refused 'not_enabled'
--   04  HAPPY PATH confirmation: one queued row, the template name, and the
--       exact three-parameter wire shape [business, service, 'Dy DD Mon, HH12:MI AM']
--   05  IDEMPOTENT: a second enqueue of the same notice creates NO second row
--       and consumes the monthly cap exactly ONCE
--   06  REMINDER format is time-only, and a RESCHEDULE produces a NEW key, so
--       the customer is reminded about the new time
--   06b THE SWEEP: an appointment 24h out is picked up by the window, and a
--       second run of the same sweep enqueues nothing new
--   07  TRIGGER: inserting a 'booked' appointment enqueues the confirmation
--   08  TRIGGER NEVER RAISES: with the enqueue function replaced by one that
--       always raises, the booking still commits
--   09  CLAIM/REPORT: the claim returns the wire payload and leases the row;
--       'sent' records sent_at + provider_message_id
--   10  STALE LEASE is refused with 40001
--   11  STATUS MONOTONIC: a late 'sent' and a late 'failed' both leave 'read'
--   12  INGEST FALLBACK: a delivery callback for a wamid that is NOT a support
--       message lands on the template row instead of being counted 'ignored'
--   13  platform_list_capability_grants_v557 refuses a non-superadmin (42501)

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _o(step text, doc jsonb) on commit drop;
create temp table _f(k text primary key, id uuid) on commit drop;

-- ---------------------------------------------------------------- 01 surface
insert into _r
select '01 surface is service-side only',
  case when (select relrowsecurity from pg_class where oid='public.whatsapp_template_sends_v557'::regclass)
        and (select count(*) from pg_policies
              where schemaname='public' and tablename='whatsapp_template_sends_v557')=0
        and not has_table_privilege('anon','public.whatsapp_template_sends_v557','SELECT')
        and not has_table_privilege('authenticated','public.whatsapp_template_sends_v557','SELECT')
        and not has_table_privilege('authenticated','public.whatsapp_template_sends_v557','INSERT')
        and not has_function_privilege('authenticated',
              'public.internal_whatsapp_claim_template_sends_v557(text,integer,integer)','EXECUTE')
        and not has_function_privilege('anon',
              'public.internal_whatsapp_claim_template_sends_v557(text,integer,integer)','EXECUTE')
        and not has_function_privilege('authenticated',
              'public.internal_whatsapp_report_template_send_v557(uuid,uuid,text,text,text,integer,integer)','EXECUTE')
        and has_function_privilege('service_role',
              'public.internal_whatsapp_claim_template_sends_v557(text,integer,integer)','EXECUTE')
        and has_function_privilege('authenticated',
              'public.platform_list_capability_grants_v557()','EXECUTE')
        and not has_function_privilege('anon',
              'public.platform_list_capability_grants_v557()','EXECUTE')
        and not has_function_privilege('authenticated',
              'app.whatsapp_enqueue_appointment_notice_v557(uuid,uuid,text)','EXECUTE')
       then 'PASS RLS on with zero policies, no browser-role grants, internals are service_role only'
       else 'FAIL surface wrong' end;

-- ------------------------------------------------------------------ fixture
-- One real tenant (Cubbly), one fixture customer whose phone the platform
-- normaliser accepts, one fixture service, two appointments. All rolled back.
do $fx$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
        v_client uuid; v_service uuid; v_appt uuid;
begin
  insert into _f values ('biz', v_biz);

  insert into public.clients(business_id, full_name, phone)
  values (v_biz, 'v557 suite customer', '+65 8555 7001')
  returning id into v_client;
  insert into _f values ('client', v_client);

  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz, 'v557 Suite Trim', 4500, 60, true)
  returning id into v_service;
  insert into _f values ('service', v_service);

  -- Inserted while the master flag is still OFF, so the AFTER INSERT trigger
  -- runs and enqueues NOTHING. Check 02 asserts exactly that.
  insert into public.appointments(
    business_id, client_id, service_id, starts_at, ends_at, status, total_cents)
  values (v_biz, v_client, v_service,
          date_trunc('hour', now()) + interval '3 days',
          date_trunc('hour', now()) + interval '3 days 1 hour',
          'booked', 4500)
  returning id into v_appt;
  insert into _f values ('appt', v_appt);
end $fx$;

-- ------------------------------------------------- 02 gate 1: master flag off
update app.platform_feature_flags set enabled=false where feature_key='whatsapp_outbound';

insert into _o select 'flag_off', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_confirmation');

insert into _r
select '02 master flag off refuses and queues nothing',
  case when (select doc->>'reason' from _o where step='flag_off')='outbound_not_enabled'
        and (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt'))=0
       then 'PASS refused by name; the booking trigger that already ran queued nothing either'
       else 'FAIL '||coalesce((select doc::text from _o where step='flag_off'),'<none>') end;

-- ------------------------------------ 03 gate 2: flag on, no capability grant
update app.platform_feature_flags set enabled=true where feature_key='whatsapp_outbound';
delete from public.business_capability_grants_v518
 where business_id=(select id from _f where k='biz')
   and capability_key='whatsapp_appointment_notification';

insert into _o select 'no_capability', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_confirmation');

insert into _r
select '03 the per-firm capability is independently necessary',
  case when (select doc->>'reason' from _o where step='no_capability')='not_enabled'
        and (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt'))=0
       then 'PASS the platform switch alone sends nothing'
       else 'FAIL '||coalesce((select doc::text from _o where step='no_capability'),'<none>') end;

-- Grant it UNLIMITED for the fixture. capability_usage_v518 carries the v33
-- append-only guard, so this suite can neither clear a live tenant's meter nor
-- reason about its absolute count - check 05 therefore counts consumption by
-- the notice's OWN idempotency key, which is the thing under test anyway.
insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, limit_unlimited)
select id,'whatsapp_appointment_notification', true, null, 'month', true from _f where k='biz'
on conflict (business_id, capability_key) do update
  set enabled=true, limit_count=null, limit_period='month', limit_unlimited=true;

-- ------------------------------------------- 04 happy path + parameter shape
insert into _o select 'send1', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_confirmation');

insert into _r
select '04 confirmation queues one row with the right wire shape',
  case when (select doc->>'status' from _o where step='send1')='ok'
        and (select doc->>'duplicate' from _o where step='send1')='false'
        and s.status='queued' and s.status_rank=0
        and s.template_name='peekaa_appt_confirmation'
        and s.language_code='en'
        and s.recipient_phone_norm='85557001'
        and jsonb_array_length(s.parameters)=3
        and (s.parameters->0->>'type')='text'
        and (s.parameters->0->>'text')=(select name from public.businesses where id=s.business_id)
        and (s.parameters->1->>'text')='v557 Suite Trim'
        and (s.parameters->2->>'text')=to_char(
              (select starts_at from public.appointments where id=s.appointment_id)
                at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM')
       then 'PASS one queued row: business, service and SGT datetime, in Meta''s parameter shape'
       else 'FAIL '||coalesce(s.parameters::text,'<no row>') end
from public.whatsapp_template_sends_v557 s
where s.appointment_id=(select id from _f where k='appt')
  and s.kind='appointment_confirmation';

-- --------------------------------------------------------- 05 idempotency
insert into _o select 'send1_again', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_confirmation');

insert into _r
select '05 a replay is one row and one quota consumption',
  case when (select doc->>'status' from _o where step='send1_again')='ok'
        and (select doc->>'duplicate' from _o where step='send1_again')='true'
        and (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt')
                and kind='appointment_confirmation')=1
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _f where k='biz')
                and capability_key='whatsapp_appointment_notification'
                and idem_key=(select doc->>'idempotency_key' from _o where step='send1'))=1
       then 'PASS the unique index absorbed the replay and the cap was spent once'
       else 'FAIL replay duplicated a notice or double-spent the cap' end;

-- ------------------------------------------ 06 reminder format + reschedule
insert into _o select 'remind1', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_reminder');

-- The customer moves the booking. starts_at changes, so the key changes.
update public.appointments
   set starts_at = starts_at + interval '2 hours',
       ends_at = ends_at + interval '2 hours'
 where id=(select id from _f where k='appt');

insert into _o select 'remind2', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _f where k='biz'), (select id from _f where k='appt'),
  'appointment_reminder');

insert into _r
select '06 reminder is time-only and a reschedule re-arms it',
  case when (select doc->>'status' from _o where step='remind1')='ok'
        and (select doc->>'duplicate' from _o where step='remind1')='false'
        and (select doc->>'template_name' from _o where step='remind1')='peekaa_appt_reminder'
        and (select doc->>'duplicate' from _o where step='remind2')='false'
        and (select doc->>'idempotency_key' from _o where step='remind1')
         <> (select doc->>'idempotency_key' from _o where step='remind2')
        and (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt')
                and kind='appointment_reminder')=2
        and (select parameters->2->>'text' from public.whatsapp_template_sends_v557
              where id=((select doc->>'send_id' from _o where step='remind1')::uuid))
            ~ '^\d{2}:\d{2} (AM|PM)$'
       then 'PASS the reminder carries only a time, and the new start time is a new notice'
       else 'FAIL reminder/reschedule wrong' end;

-- ------------------------------------------------ 06b the 24h reminder sweep
-- The cron entry point, not the primitive: an appointment 24 hours out is
-- picked up by the window, and a second run of the same sweep adds nothing.
do $t6b$
declare v_appt uuid;
begin
  insert into public.appointments(
    business_id, client_id, service_id, starts_at, ends_at, status, total_cents)
  values ((select id from _f where k='biz'), (select id from _f where k='client'),
          (select id from _f where k='service'),
          now() + interval '24 hours', now() + interval '25 hours',
          'booked', 4500)
  returning id into v_appt;
  insert into _f values ('appt_sweep', v_appt);
end $t6b$;

-- The booking trigger has already queued this one's CONFIRMATION; the sweep is
-- about its REMINDER, so the counts below are kind-scoped.
insert into _o select 'sweep1', app.run_whatsapp_reminder_sweep_v557(5000);
insert into _o select 'sweep2', app.run_whatsapp_reminder_sweep_v557(5000);

insert into _r
select '06b the 24h sweep picks the appointment up exactly once',
  case when (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt_sweep')
                and kind='appointment_reminder')=1
        and ((select doc->>'enqueued' from _o where step='sweep1')::int) >= 1
        and ((select doc->>'enqueued' from _o where step='sweep2')::int) = 0
        and ((select doc->>'duplicate' from _o where step='sweep2')::int) >= 1
       then 'PASS the window found it, and the second run was pure duplicate absorption'
       else 'FAIL sweep1='||coalesce((select doc::text from _o where step='sweep1'),'?')
            ||' sweep2='||coalesce((select doc::text from _o where step='sweep2'),'?') end;

-- ----------------------------------------------------- 07 the booked trigger
do $t7$
declare v_appt uuid;
begin
  insert into public.appointments(
    business_id, client_id, service_id, starts_at, ends_at, status, total_cents)
  values ((select id from _f where k='biz'), (select id from _f where k='client'),
          (select id from _f where k='service'),
          date_trunc('hour', now()) + interval '5 days',
          date_trunc('hour', now()) + interval '5 days 1 hour',
          'booked', 4500)
  returning id into v_appt;
  insert into _f values ('appt_trigger', v_appt);
end $t7$;

insert into _r
select '07 booking a slot enqueues its confirmation',
  case when (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt_trigger')
                and kind='appointment_confirmation' and status='queued')=1
       then 'PASS the AFTER INSERT trigger queued exactly one confirmation'
       else 'FAIL the trigger queued '||(select count(*)::text from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='appt_trigger')) end;

-- ------------------------------------------- 08 the trigger swallows failures
-- The enqueue function is replaced by one that always raises. If the trigger
-- did not swallow, the INSERT below would abort and no appointment would exist.
create temp table _def(src text) on commit drop;
insert into _def select pg_get_functiondef(
  'app.whatsapp_enqueue_appointment_notice_v557(uuid,uuid,text)'::regprocedure);

create or replace function app.whatsapp_enqueue_appointment_notice_v557(
  p_business uuid, p_appointment uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $broken$
begin
  raise exception 'v557 suite: forced enqueue failure' using errcode = 'P0001';
end
$broken$;

do $t8$
declare v_appt uuid; v_ok boolean := true; v_err text := null;
begin
  begin
    insert into public.appointments(
      business_id, client_id, service_id, starts_at, ends_at, status, total_cents)
    values ((select id from _f where k='biz'), (select id from _f where k='client'),
            (select id from _f where k='service'),
            date_trunc('hour', now()) + interval '7 days',
            date_trunc('hour', now()) + interval '7 days 1 hour',
            'booked', 4500)
    returning id into v_appt;
  exception when others then
    v_ok := false; v_err := sqlstate||' '||sqlerrm;
  end;

  insert into _r values ('08 a notification failure never breaks a booking',
    case when v_ok and v_appt is not null
          and exists (select 1 from public.appointments where id=v_appt)
          and not exists (select 1 from public.whatsapp_template_sends_v557
                           where appointment_id=v_appt)
         then 'PASS the booking committed with a raising enqueue; no notice was queued'
         else 'FAIL the booking was aborted by a notification failure ('||coalesce(v_err,'?')||')' end);
end $t8$;

-- Put the real function back before anything else uses it.
do $restore$ begin execute (select src from _def); end $restore$;

insert into _r
select '08b the real enqueue function is restored',
  case when pg_get_functiondef('app.whatsapp_enqueue_appointment_notice_v557(uuid,uuid,text)'::regprocedure)
            = (select src from _def)
       then 'PASS the suite left the definition exactly as it found it'
       else 'FAIL the forced-failure stub was not fully restored' end;

-- ------------------------------------------------------- 09 claim and report
create temp table _claim(message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameters jsonb,
  attempt_count integer, lease_token uuid) on commit drop;

-- Narrow the queue to this suite's rows so a live backlog cannot steal the lease.
update public.whatsapp_template_sends_v557
   set next_attempt_at = now() + interval '1 day'
 where appointment_id is distinct from (select id from _f where k='appt')
   and status in ('queued','processing');

insert into _claim
select * from public.internal_whatsapp_claim_template_sends_v557('v557-suite-worker', 1, 120);

insert into _r
select '09 claim leases the row and returns the wire payload',
  case when (select count(*) from _claim)=1
        and (select template_name from _claim) is not null
        and (select jsonb_array_length(parameters) from _claim)=3
        and (select recipient_phone_norm from _claim)='85557001'
        and (select lease_token from _claim) is not null
        and s.status='processing' and s.status_rank=10
        and s.lease_until > now() and s.leased_by='v557-suite-worker'
       then 'PASS one row claimed, leased, and returned with template + parameters'
       else 'FAIL claim protocol wrong' end
from public.whatsapp_template_sends_v557 s
where s.id=(select message_id from _claim);

insert into _o select 'report_sent', public.internal_whatsapp_report_template_send_v557(
  (select message_id from _claim), (select lease_token from _claim),
  'sent', 'wamid.SUITE557', null, 200, null);

insert into _r
select '09b sent records the provider id, the time and releases the lease',
  case when s.status='sent' and s.status_rank=20
        and s.provider_message_id='wamid.SUITE557'
        and s.sent_at is not null and s.attempt_count=1
        and s.lease_token is null and s.lease_until is null
        and s.next_attempt_at is null
       then 'PASS the send is terminal, evidenced and unleased'
       else 'FAIL report(sent) wrong: '||s.status end
from public.whatsapp_template_sends_v557 s
where s.id=(select message_id from _claim);

-- ------------------------------------------------------- 10 stale lease
do $t10$
declare v_code text;
begin
  begin
    perform public.internal_whatsapp_report_template_send_v557(
      (select message_id from _claim), gen_random_uuid(), 'sent', 'wamid.WRONG');
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  insert into _r values ('10 a stale lease cannot report',
    case when v_code='40001' then 'PASS a worker holding a stale lease is refused (40001)'
         else 'FAIL stale lease accepted ('||v_code||')' end);
end $t10$;

-- ------------------------------------------------------- 11 monotonic status
update public.whatsapp_template_sends_v557
   set status='read', status_rank=app.support_status_rank_v535('read')
 where id=(select message_id from _claim);

-- A LATE 'sent', then a LATE 'failed'. Both are advance-only, so both miss.
update public.whatsapp_template_sends_v557
   set status='sent', status_rank=app.support_status_rank_v535('sent')
 where id=(select message_id from _claim)
   and status_rank < app.support_status_rank_v535('sent');
update public.whatsapp_template_sends_v557
   set status='failed', status_rank=app.support_status_rank_v535('failed')
 where id=(select message_id from _claim)
   and status_rank < app.support_status_rank_v535('failed');

insert into _r
select '11 status is monotonic',
  case when status='read' and status_rank=40
       then 'PASS a late sent and a late failed both left read alone'
       else 'FAIL status downgraded to '||status end
from public.whatsapp_template_sends_v557 where id=(select message_id from _claim);

-- --------------------------------------------- 12 ingest falls back to v557
-- Reset to 'sent' so a genuine 'delivered' callback has somewhere to advance to.
update public.whatsapp_template_sends_v557
   set status='sent', status_rank=app.support_status_rank_v535('sent')
 where id=(select message_id from _claim);

insert into public.whatsapp_webhook_events(
  payload_sha256, payload, signature_verified, waba_id, phone_number_id,
  entry_kinds, meta_message_ids, processing_status)
values (
  substr(md5('v557-suite-delivered'||random()::text)||md5('v557'),1,64),
  jsonb_build_object('object','whatsapp_business_account','entry',
    jsonb_build_array(jsonb_build_object('id','1725929281961827','changes',
      jsonb_build_array(jsonb_build_object('field','messages','value',
        jsonb_build_object('statuses', jsonb_build_array(jsonb_build_object(
          'id','wamid.SUITE557','status','delivered',
          'timestamp', extract(epoch from now())::bigint::text)))))))),
  true, '1725929281961827','1277171422152387', array['statuses'],
  array['wamid.SUITE557'], 'pending');

create temp table _ing(doc jsonb) on commit drop;
-- A large limit deliberately: the sweep reads the last two days of webhook
-- rows oldest-first, and on a busy day the row planted above would fall outside
-- a limit of 200 and this check would pass for the wrong reason.
insert into _ing select app.support_ingest_status_v535(100000);

insert into _r
select '12 a delivery callback lands on the template row',
  case when s.status='delivered' and s.status_rank=30
        and ((select doc->>'applied' from _ing)::int) >= 1
       then 'PASS the ingest fell back to whatsapp_template_sends_v557 instead of ignoring the receipt'
       else 'FAIL status='||s.status||' applied='||coalesce((select doc->>'applied' from _ing),'?') end
from public.whatsapp_template_sends_v557 s
where s.id=(select message_id from _claim);

-- -------------------------------------------------- 13 superadmin-only read
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p,'role','authenticated')::text, true);
end $$;

do $t13$
declare v_code text; v_uid uuid;
begin
  -- A real, non-superadmin business owner.
  select s.user_id into v_uid from public.staff s
   where s.business_id=(select id from _f where k='biz') and s.active
     and s.user_id is not null
     and not exists (select 1 from public.super_admins a where a.user_id=s.user_id)
   limit 1;
  perform pg_temp.as_user(coalesce(v_uid, gen_random_uuid()));
  begin
    perform public.platform_list_capability_grants_v557();
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  perform pg_temp.as_user(null);
  insert into _r values ('13 the cross-firm roster is superadmin-only',
    case when v_code='42501' then 'PASS a business owner is refused (42501)'
         else 'FAIL a non-superadmin read the platform roster ('||v_code||')' end);
end $t13$;

update app.platform_feature_flags set enabled=false where feature_key='whatsapp_outbound';

select k as check_name, v as result from _r order by k;

rollback;
