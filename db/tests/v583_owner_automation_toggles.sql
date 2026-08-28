-- Rollback-only acceptance for nestly_v583 — the owner's four automation
-- switches suppress their own lane, only their own lane, and can never let a
-- message past a gate that would otherwise have stopped it.
-- Run: supabase db query --linked -f db/tests/v583_owner_automation_toggles.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Everything the suite depends on is armed INSIDE the transaction — platform
-- flags, capability grants, template statuses, the demo flag — so the result
-- does not depend on prod's current configuration, and prod's configuration is
-- not changed by running it.
--
--   01  a business row is born true / true / FALSE / true
--   02  unknown lane fails closed
--   03  confirmation on  -> queued
--   04  confirmation off -> automation_off_for_business, reminder unaffected
--   05  a change-of-time notice follows the CONFIRMATION switch
--   06  reminder off -> only the reminder refuses
--   07  short-notice off -> only the short lane refuses
--   08  switch ON + capability OFF  -> capability reason, nothing queued
--   09  switch ON + platform flag OFF -> outbound_not_enabled
--   10  switch ON + template draft  -> template_not_approved
--   11  bring-back on  -> queued
--   12  bring-back off -> suppressed automation_off_for_business
--   13  bring-back on + consent missing -> consent_missing (no bypass)
--   14  bring-back on + platform hold  -> platform_hold (no bypass)
--   15  bring-back on + cooldown       -> cooldown_active (no bypass)
--   16  bring-back on + capability off -> capability_disabled (no bypass)
--   17  the bring-back switch never touches the appointment lane
--   18  nothing was ever dispatched

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _f(label text primary key, id uuid) on commit drop;

create temp table _base(k text primary key, n bigint) on commit drop;
insert into _base values
  ('http_queue', (select count(*) from net.http_request_queue));

do $setup$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid;
  v_service uuid;
  v_campaign uuid;
  v_modules_ok boolean;
begin
  update app.platform_feature_flags set enabled = true
   where feature_key in ('whatsapp_outbound','whatsapp_retention_sends');

  -- enabled_modules is deliberately NOT touched: business_sector_modules_guard_v75
  -- refuses any change to it, and Cubbly already carries appointments, clients
  -- and retention. The suite asserts that prerequisite instead of forcing it.
  select b.enabled_modules @> array['appointments','clients','retention']
    into v_modules_ok
    from public.businesses b where b.id = v_biz;
  if not coalesce(v_modules_ok, false) then
    raise exception 'v583 suite precondition: Cubbly is missing a required module';
  end if;

  update public.businesses
     set -- Cubbly is is_demo, and business_may_initiate_comms_v572 refuses
         -- MARKETING for a demo firm. Cleared inside the tx so the bring-back
         -- lane is exercised on its own merits; rolled back with everything else.
         is_demo = false,
         -- The switches start in a known state; each check sets the one it owns.
         wa_confirmation_enabled = true,
         wa_reminder_24h_enabled = true,
         wa_reminder_short_enabled = true,
         wa_bringback_enabled = true
   where id = v_biz;

  insert into public.business_capability_grants_v518(
    business_id, capability_key, enabled, limit_count, limit_period, note)
  values (v_biz, 'whatsapp_appointment_notification', true, null, 'month', 'v583 suite arm'),
         (v_biz, 'whatsapp_retention', true, null, 'month', 'v583 suite arm')
  on conflict (business_id, capability_key) do update
    set enabled = true, limit_count = null, updated_at = now();

  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (v_biz, 'v583 suite client', '+65 8555 9001', true)
  returning id into v_client;
  insert into _f values ('client', v_client);

  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz, 'v583 suite service', 5000, 30, true)
  returning id into v_service;
  insert into _f values ('service', v_service);

  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, expiry_days, active)
  values (v_biz, 'v583 suite campaign', 'Free coffee', 30, 30, true)
  returning id into v_campaign;
  insert into _f values ('campaign', v_campaign);
end
$setup$;

-- ------------------------------------------------ 01 the defaults are the copy
-- A business row must be BORN with three lanes on and the short-notice lane
-- off — the exact claim the migration header makes. Asserted on the column
-- defaults rather than by inserting a business, because tenant creation runs a
-- sector-entitlement guard that has nothing to do with this migration.
insert into _r
select '01 a business row is born true/true/FALSE/true',
  case when (select count(*) from information_schema.columns c
              where c.table_schema='public' and c.table_name='businesses'
                and c.is_nullable='NO'
                and (c.column_name, c.column_default) in (
                  ('wa_confirmation_enabled','true'),
                  ('wa_reminder_24h_enabled','true'),
                  ('wa_reminder_short_enabled','false'),
                  ('wa_bringback_enabled','true'))) = 4
       then 'PASS confirmation, reminder and bring-back default on; short-notice defaults off until its message is live; all four NOT NULL'
       else 'FAIL '||coalesce((select string_agg(c.column_name||'='||coalesce(c.column_default,'<null>')||'/'||c.is_nullable, ' ')
              from information_schema.columns c
             where c.table_schema='public' and c.table_name='businesses'
               and c.column_name in ('wa_confirmation_enabled','wa_reminder_24h_enabled',
                                     'wa_reminder_short_enabled','wa_bringback_enabled')),'<no columns>') end;

-- ---------------------------------------------------- 02 unknown lane = closed
insert into _r
select '02 an unknown lane fails closed',
  case when app.business_automation_enabled_v583('8492e8d6-8888-4383-ada0-7e1ed69f0caa','no_such_lane') = false
        and app.business_automation_enabled_v583(gen_random_uuid(),'appointment_confirmation') = false
       then 'PASS an unmapped kind and an unknown business both resolve false'
       else 'FAIL the helper returned true for something it does not know' end;

-- --------------------------------------------------- appointments to work with
-- Created with the confirmation switch OFF so the AFTER INSERT trigger refuses
-- and leaves each idempotency key free for the direct calls below. That the
-- trigger path refuses at all is itself part of the evidence.
do $appts$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid := (select id from _f where label='client');
  v_service uuid := (select id from _f where label='service');
  v_id uuid;
  i int;
begin
  update public.businesses set wa_confirmation_enabled = false where id = v_biz;
  for i in 1..7 loop
    insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
    values (v_biz, v_client, v_service,
            now() + make_interval(days => i), now() + make_interval(days => i) + interval '30 min',
            'booked')
    returning id into v_id;
    insert into _f values ('appt'||i, v_id);
  end loop;

  insert into _r
  select '02b the AFTER INSERT trigger itself honours the switch',
    case when (select count(*) from public.whatsapp_template_sends_v557 s
                join _f f on f.id = s.appointment_id
               where f.label like 'appt%') = 0
         then 'PASS seven bookings with confirmations switched off queued nothing'
         else 'FAIL rows were queued while the owner switch was off' end;
end
$appts$;

-- ------------------------------------------------------ 03 / 04 confirmations
do $conf$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_on jsonb; v_off jsonb; v_rem jsonb;
begin
  update public.businesses set wa_confirmation_enabled = true where id = v_biz;
  v_on := app.whatsapp_enqueue_appointment_notice_v557(
            v_biz, (select id from _f where label='appt1'), 'appointment_confirmation');

  update public.businesses set wa_confirmation_enabled = false where id = v_biz;
  v_off := app.whatsapp_enqueue_appointment_notice_v557(
            v_biz, (select id from _f where label='appt2'), 'appointment_confirmation');
  -- The reminder switch is untouched, so the reminder lane must be unaffected.
  v_rem := app.whatsapp_enqueue_appointment_notice_v557(
            v_biz, (select id from _f where label='appt2'), 'appointment_reminder');

  insert into _r
  select '03 confirmation switch ON -> the confirmation is queued',
    case when v_on->>'status' = 'ok' and (v_on->>'duplicate')::boolean = false
         then 'PASS' else 'FAIL '||v_on::text end;

  insert into _r
  select '04 confirmation switch OFF -> refused by name, and ONLY that lane',
    case when v_off->>'status' = 'refused'
          and v_off->>'reason' = 'automation_off_for_business'
          and v_rem->>'status' = 'ok'
         then 'PASS the confirmation refused, the reminder for the same appointment still queued'
         else 'FAIL confirmation='||v_off::text||' reminder='||v_rem::text end;
end
$conf$;

-- ------------------------------- 05 a change of time follows the confirmation
do $upd$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_off jsonb; v_on jsonb;
begin
  -- appointment_updated ships with a draft template; approve it inside the tx
  -- so this check measures the SWITCH and not the template gate. Check 10
  -- proves the template gate separately, and proves the switch cannot pass it.
  update public.whatsapp_template_registry_v551
     set status = 'approved'
   where template_key in ('appointment_updated','appointment_reminder_short');

  update public.businesses set wa_confirmation_enabled = false where id = v_biz;
  v_off := app.whatsapp_enqueue_appointment_notice_v557(
            v_biz, (select id from _f where label='appt3'), 'appointment_updated');

  update public.businesses set wa_confirmation_enabled = true where id = v_biz;
  v_on := app.whatsapp_enqueue_appointment_notice_v557(
            v_biz, (select id from _f where label='appt3'), 'appointment_updated');

  insert into _r
  select '05 a change-of-time notice obeys the CONFIRMATION switch',
    case when v_off->>'reason' = 'automation_off_for_business' and v_on->>'status' = 'ok'
         then 'PASS off refuses it, on queues it — mapped to confirmations, as the header states'
         else 'FAIL off='||v_off::text||' on='||v_on::text end;
end
$upd$;

-- ------------------------------------------------------------- 06 / 07 reminders
do $rem$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_r_off jsonb; v_c_ok jsonb; v_s_ok jsonb;
  v_s_off jsonb; v_r_ok jsonb;
begin
  update public.businesses
     set wa_confirmation_enabled = true, wa_reminder_24h_enabled = false,
         wa_reminder_short_enabled = true
   where id = v_biz;
  v_r_off := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt4'), 'appointment_reminder');
  v_c_ok  := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt4'), 'appointment_confirmation');
  v_s_ok  := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt4'), 'appointment_reminder_short');

  insert into _r
  select '06 the day-before switch OFF suppresses only the day-before reminder',
    case when v_r_off->>'reason' = 'automation_off_for_business'
          and v_c_ok->>'status' = 'ok' and v_s_ok->>'status' = 'ok'
         then 'PASS confirmation and short-notice unaffected'
         else 'FAIL reminder='||v_r_off::text||' conf='||v_c_ok::text||' short='||v_s_ok::text end;

  update public.businesses
     set wa_reminder_24h_enabled = true, wa_reminder_short_enabled = false
   where id = v_biz;
  v_s_off := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt5'), 'appointment_reminder_short');
  v_r_ok  := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt5'), 'appointment_reminder');

  insert into _r
  select '07 the short-notice switch OFF suppresses only the short-notice lane',
    case when v_s_off->>'reason' = 'automation_off_for_business' and v_r_ok->>'status' = 'ok'
         then 'PASS the day-before reminder for the same appointment still queued'
         else 'FAIL short='||v_s_off::text||' reminder='||v_r_ok::text end;
end
$rem$;

-- ============================================================================
-- THE CEILING. Each of the next three has the owner switch ON — the only thing
-- that changes is a gate ABOVE it — and each must still refuse, with the
-- upstream gate's own reason, not the switch's.
-- ============================================================================
do $ceiling$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_cap jsonb; v_flag jsonb; v_tpl jsonb;
  v_queued_before bigint;
  v_queued_after bigint;
begin
  update public.businesses
     set wa_confirmation_enabled = true, wa_reminder_24h_enabled = true,
         wa_reminder_short_enabled = true, wa_bringback_enabled = true
   where id = v_biz;

  select count(*) into v_queued_before
    from public.whatsapp_template_sends_v557 s join _f f on f.id = s.appointment_id;

  -- 08 capability withdrawn
  update public.business_capability_grants_v518 set enabled = false
   where business_id = v_biz and capability_key = 'whatsapp_appointment_notification';
  v_cap := app.whatsapp_enqueue_appointment_notice_v557(
             v_biz, (select id from _f where label='appt6'), 'appointment_confirmation');
  update public.business_capability_grants_v518 set enabled = true
   where business_id = v_biz and capability_key = 'whatsapp_appointment_notification';

  -- 09 platform kill switch off
  update app.platform_feature_flags set enabled = false where feature_key = 'whatsapp_outbound';
  v_flag := app.whatsapp_enqueue_appointment_notice_v557(
              v_biz, (select id from _f where label='appt6'), 'appointment_confirmation');
  update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_outbound';

  -- 10 template back to draft
  update public.whatsapp_template_registry_v551 set status = 'draft'
   where template_key = 'appointment_reminder_short';
  v_tpl := app.whatsapp_enqueue_appointment_notice_v557(
             v_biz, (select id from _f where label='appt6'), 'appointment_reminder_short');
  update public.whatsapp_template_registry_v551 set status = 'approved'
   where template_key = 'appointment_reminder_short';

  select count(*) into v_queued_after
    from public.whatsapp_template_sends_v557 s join _f f on f.id = s.appointment_id;

  insert into _r
  select '08 switch ON but the capability is OFF -> nothing sends',
    case when v_cap->>'status' = 'refused'
          and v_cap->>'reason' <> 'automation_off_for_business'
         then 'PASS refused as '||coalesce(v_cap->>'reason','?')||' — the capability, not the switch, answered'
         else 'FAIL '||v_cap::text end;

  insert into _r
  select '09 switch ON, capability ON, platform flag OFF -> nothing sends',
    case when v_flag->>'status' = 'refused' and v_flag->>'reason' = 'outbound_not_enabled'
         then 'PASS the platform kill switch is upstream of everything'
         else 'FAIL '||v_flag::text end;

  insert into _r
  select '10 switch ON but the message is still a draft -> nothing sends',
    case when v_tpl->>'status' = 'refused' and v_tpl->>'reason' = 'template_not_approved'
         then 'PASS an owner cannot switch on a lane that has no approved message'
         else 'FAIL '||v_tpl::text end;

  insert into _r
  select '10b none of the three ceiling refusals queued a row',
    case when v_queued_after = v_queued_before
         then 'PASS the send table did not grow across checks 08-10'
         else 'FAIL the send table grew by '||(v_queued_after - v_queued_before)::text end;
end
$ceiling$;

-- ============================================================================
-- THE BRING-BACK LANE. One fresh client per scenario: a queued send starts the
-- 30-day cooldown, so reusing a client would make later checks measure the
-- cooldown instead of the thing under test.
-- ============================================================================
create temp table _bb(label text primary key, client_id uuid, grant_id uuid) on commit drop;

create or replace function pg_temp.v583_bb(p_label text, p_consent boolean default true)
returns void language plpgsql as $bb$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid;
  v_grant uuid;
begin
  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (v_biz, 'v583 bb '||p_label, '+65 855'||lpad((random()*89999+10000)::int::text,5,'0'), p_consent)
  returning id into v_client;

  if p_consent then
    insert into public.consents(business_id, client_id, channel, purpose, action, source)
    values (v_biz, v_client, 'whatsapp', 'marketing', 'granted', 'v583 suite');
  end if;

  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days, cycle_key, expires_at)
  values (v_biz, (select id from _f where label='campaign'), v_client,
          'Free coffee', 30, current_date, now() + interval '30 days')
  returning id into v_grant;

  insert into _bb values (p_label, v_client, v_grant);
end
$bb$;

do $bblanes$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
begin
  -- 11 everything on
  update public.businesses set wa_bringback_enabled = true where id = v_biz;
  perform pg_temp.v583_bb('on');

  -- 12 switch off
  update public.businesses set wa_bringback_enabled = false where id = v_biz;
  perform pg_temp.v583_bb('off');

  -- 17 the appointment lane is untouched while bring-back is off
  insert into _f
  select 'appt7_conf',
    (app.whatsapp_enqueue_appointment_notice_v557(
       v_biz, (select id from _f where label='appt7'), 'appointment_confirmation')->>'send_id')::uuid;

  -- 13 switch on, no consent
  update public.businesses set wa_bringback_enabled = true where id = v_biz;
  perform pg_temp.v583_bb('noconsent', false);

  -- 14 switch on, platform hold
  insert into public.platform_retention_holds_v574(business_id, campaign_id, held, reason)
  values (v_biz, null, true, 'v583 suite hold')
  on conflict do nothing;
  perform pg_temp.v583_bb('held');
  delete from public.platform_retention_holds_v574
   where business_id = v_biz and reason = 'v583 suite hold';
end
$bblanes$;

-- 15 the cooldown: a SECOND grant for the client whose first send queued at
-- check 11. Everything else about this customer is identical and permitted.
do $cooldown$
declare
  v_client uuid := (select client_id from _bb where label='on');
  v_grant uuid;
begin
  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days, cycle_key, expires_at)
  values ('8492e8d6-8888-4383-ada0-7e1ed69f0caa', (select id from _f where label='campaign'),
          v_client, 'Free coffee again', 30, current_date - 2, now() + interval '30 days')
  returning id into v_grant;
  insert into _bb values ('cooldown', v_client, v_grant);
end
$cooldown$;

-- 16 switch on, capability off
do $bbcap$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
begin
  update public.business_capability_grants_v518 set enabled = false
   where business_id = v_biz and capability_key = 'whatsapp_retention';
  perform pg_temp.v583_bb('nocap');
  update public.business_capability_grants_v518 set enabled = true
   where business_id = v_biz and capability_key = 'whatsapp_retention';
end
$bbcap$;

insert into _r
select '11 bring-back switch ON -> the voucher message is queued',
  case when (select s.status from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='on')) = 'queued'
       then 'PASS'
       else 'FAIL '||coalesce((select s.status||'/'||coalesce(s.suppressed_reason,'-')
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='on')),'<no row>') end;

insert into _r
select '12 bring-back switch OFF -> suppressed automation_off_for_business',
  case when (select s.status from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='off')) = 'suppressed'
        and (select s.suppressed_reason from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='off')) = 'automation_off_for_business'
       then 'PASS'
       else 'FAIL '||coalesce((select s.status||'/'||coalesce(s.suppressed_reason,'-')
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='off')),'<no row>') end;

insert into _r
select '13 switch ON cannot bypass consent',
  case when (select s.suppressed_reason from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='noconsent')) = 'consent_missing'
       then 'PASS consent is downstream of the switch and still refuses'
       else 'FAIL '||coalesce((select coalesce(s.suppressed_reason,s.status)
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='noconsent')),'<no row>') end;

insert into _r
select '14 switch ON cannot bypass a platform hold',
  case when (select s.suppressed_reason from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='held')) = 'platform_hold'
       then 'PASS the hold is upstream of the switch and answers first'
       else 'FAIL '||coalesce((select coalesce(s.suppressed_reason,s.status)
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='held')),'<no row>') end;

insert into _r
select '15 switch ON cannot bypass the 30-day cooldown',
  case when (select s.suppressed_reason from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='cooldown')) = 'cooldown_active'
       then 'PASS a second voucher to the same customer is still held back'
       else 'FAIL '||coalesce((select coalesce(s.suppressed_reason,s.status)
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='cooldown')),'<no row>') end;

insert into _r
select '16 switch ON cannot bypass the capability',
  case when (select s.suppressed_reason from public.retention_sends_v551 s
              where s.grant_id = (select grant_id from _bb where label='nocap')) = 'capability_disabled'
       then 'PASS'
       else 'FAIL '||coalesce((select coalesce(s.suppressed_reason,s.status)
              from public.retention_sends_v551 s
             where s.grant_id = (select grant_id from _bb where label='nocap')),'<no row>') end;

insert into _r
select '17 the bring-back switch never touches the appointment lane',
  case when (select id from _f where label='appt7_conf') is not null
        and (select status from public.whatsapp_template_sends_v557
              where id = (select id from _f where label='appt7_conf')) = 'queued'
       then 'PASS a confirmation queued normally while bring-back was switched off'
       else 'FAIL the appointment confirmation did not queue with bring-back off' end;

insert into _r
select '18 no HTTP request was ever queued by this suite',
  case when (select count(*) from net.http_request_queue) = (select n from _base where k = 'http_queue')
       then 'PASS net.http_request_queue is unchanged — this suite queues rows, it never dispatches'
       else 'FAIL net.http_request_queue grew during the suite' end;

select k as check_name, v as result from _r order by k;

rollback;
