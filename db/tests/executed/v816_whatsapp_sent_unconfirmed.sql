-- Rollback-only nestly_v816 acceptance: an outcome the database never learned can never be
-- sent again.
--
-- WHAT THE BUG WAS
--   Both WhatsApp claim RPCs re-claimed on
--       status in ('queued','processing') and (lease_until is null or lease_until < now())
--   so a row whose worker died — or whose outcome nestly_v687's reportSendOutcome could not
--   persist after four attempts — came back around on the next cron run and the customer's
--   phone buzzed a second time. v687 could only count that residual (`unreported`) and say so.
--
--   Owner ruling: a possibly-undelivered message is preferred to a duplicate WhatsApp. So the
--   queue gets a terminal 'sent_unconfirmed', reached only through a named, audited quarantine.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--    1. rank — sent_unconfirmed is strictly between sent and failed, so a late 'sent' callback
--       cannot un-quarantine a row and Meta can still advance it to delivered/read.
--    2. support lane — a 'processing' row with an expired lease is quarantined by the explicit
--       sweep: status, rank, cleared lease, named error code.
--    3. the evidence is not silence — audit_log carries the lease token, the worker that held
--       it, when it expired, and why.
--    4. the quarantined row is NOT returned by internal_support_claim_outbound_v535, and is
--       still sent_unconfirmed afterwards. This is the assertion that fails before the migration.
--    5. positive control — a fresh 'queued' row in the same call IS claimed. The fix is not
--       "stop claiming".
--    6. sensitivity control — a 'processing' row whose lease is STILL VALID is neither
--       quarantined nor claimed. The predicate is "stranded", not "in flight".
--    7. internal_support_report_outbound_v535 on a quarantined row, with the lease it used to
--       hold, refuses with 40001 — the same stale-lease code the dispatcher already handles as
--       non-retryable.
--    8. template lane — same quarantine, same evidence, and the v580 claim does not return it.
--    9. the targeted form — internal_whatsapp_quarantine_send_v816 retires ONE in-flight row
--       whose lease the caller holds, is idempotent on the second call (the dispatcher retries
--       it), and refuses a caller holding the wrong lease with 40001.
--   10. the duplicate cannot come back by the enqueue door —
--       app.appointment_already_reminded_v581 counts a quarantined reminder as already sent.
--   11. ACL — service_role may execute both new RPCs; anon and authenticated may not.
--
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure; the gate at the bottom is fatal.
--   supabase db query --linked -f db/tests/v816_whatsapp_sent_unconfirmed.sql

begin;

create temp table v816_out(seq integer, step text, outcome text) on commit drop;
create temp table v816_fx(label text primary key, id uuid, lease uuid) on commit drop;

do $v816_fixture$
declare
  v_biz uuid; v_conv uuid; v_client uuid; v_appt uuid;
  v_stranded uuid; v_fresh uuid; v_inflight uuid; v_targeted uuid;
  v_tpl_stranded uuid; v_tpl_reminder uuid;
  v_lease_stranded uuid := gen_random_uuid();
  v_lease_inflight uuid := gen_random_uuid();
  v_lease_targeted uuid := gen_random_uuid();
  v_lease_tpl uuid := gen_random_uuid();
begin
  execute 'reset role';

  insert into public.businesses(name, slug, industry, enabled_modules)
  values ('V816 quarantine lab', 'v816-' || substr(gen_random_uuid()::text, 1, 8), 'test',
          array['dashboard','support','appointments'])
  returning id into v_biz;

  insert into public.clients(business_id, full_name, phone)
  values (v_biz, 'V816 Customer', '+65 9555 0816')
  returning id into v_client;

  insert into public.appointments(business_id, client_id, starts_at, ends_at, status)
  values (v_biz, v_client, now() + interval '20 hours', now() + interval '21 hours', 'booked')
  returning id into v_appt;

  insert into public.support_conversations_v530(
    business_id, channel, customer_phone_norm, state, routing_source,
    opened_at, last_inbound_at, service_window_expires_at)
  values (v_biz, 'whatsapp', '95550816', 'open', 'entry_token',
          now(), now(), now() + interval '20 hours')
  returning id into v_conv;

  -- (a) STRANDED: Meta may have taken it, the database never learned. Lease expired.
  insert into public.support_messages_v530(
    conversation_id, business_id, direction, body, rendered_body, occurred_at,
    status, status_rank, idempotency_key, queued_at, next_attempt_at, attempt_count,
    lease_token, leased_by, lease_until)
  values (v_conv, v_biz, 'outbound', 'stranded', 'V816: stranded', now(),
          'processing', app.support_status_rank_v535('processing'),
          'v816-stranded-key', now() - interval '10 minutes', now() - interval '10 minutes', 1,
          v_lease_stranded, 'worker-v816-dead', now() - interval '3 minutes')
  returning id into v_stranded;

  -- (b) FRESH: ordinary work, must still be claimable.
  insert into public.support_messages_v530(
    conversation_id, business_id, direction, body, rendered_body, occurred_at,
    status, status_rank, idempotency_key, queued_at, next_attempt_at, attempt_count)
  values (v_conv, v_biz, 'outbound', 'fresh', 'V816: fresh', now(),
          'queued', app.support_status_rank_v535('queued'),
          'v816-fresh-key', now() - interval '1 minute', now() - interval '1 minute', 0)
  returning id into v_fresh;

  -- (c) IN FLIGHT: another worker holds a lease that has NOT expired. Touch nothing.
  insert into public.support_messages_v530(
    conversation_id, business_id, direction, body, rendered_body, occurred_at,
    status, status_rank, idempotency_key, queued_at, next_attempt_at, attempt_count,
    lease_token, leased_by, lease_until)
  values (v_conv, v_biz, 'outbound', 'inflight', 'V816: in flight', now(),
          'processing', app.support_status_rank_v535('processing'),
          'v816-inflight-key', now() - interval '5 seconds', now() - interval '5 seconds', 1,
          v_lease_inflight, 'worker-v816-alive', now() + interval '110 seconds')
  returning id into v_inflight;

  -- (d) TARGETED: this worker still holds the lease and its report write just failed.
  insert into public.support_messages_v530(
    conversation_id, business_id, direction, body, rendered_body, occurred_at,
    status, status_rank, idempotency_key, queued_at, next_attempt_at, attempt_count,
    lease_token, leased_by, lease_until)
  values (v_conv, v_biz, 'outbound', 'targeted', 'V816: targeted', now(),
          'processing', app.support_status_rank_v535('processing'),
          'v816-targeted-key', now() - interval '20 seconds', now() - interval '20 seconds', 1,
          v_lease_targeted, 'worker-v816-reporting', now() + interval '100 seconds')
  returning id into v_targeted;

  -- (e) TEMPLATE lane, stranded the same way.
  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm, template_name, language_code,
    parameters, idempotency_key, status, status_rank, attempt_count,
    queued_at, next_attempt_at, lease_token, leased_by, lease_until)
  values (v_biz, v_appt, 'appointment_confirmation', '95550816', 'v816_confirmation', 'en',
          '[]'::jsonb, 'v816-tpl-stranded-key', 'processing',
          app.support_status_rank_v535('processing'), 1,
          now() - interval '10 minutes', now() - interval '10 minutes',
          v_lease_tpl, 'worker-v816-dead', now() - interval '4 minutes')
  returning id into v_tpl_stranded;

  -- (f) TEMPLATE lane, a REMINDER for the same appointment, already quarantined. The reminder
  --     sweep must treat this appointment as already reminded.
  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm, template_name, language_code,
    parameters, idempotency_key, status, status_rank, attempt_count, queued_at)
  values (v_biz, v_appt, 'appointment_reminder', '95550816', 'v816_reminder', 'en',
          '[]'::jsonb, 'v816-tpl-reminder-key', 'sent_unconfirmed',
          app.support_status_rank_v535('sent_unconfirmed'), 1, now() - interval '2 hours')
  returning id into v_tpl_reminder;

  insert into v816_fx(label, id, lease) values
    ('business', v_biz, null),
    ('appointment', v_appt, null),
    ('stranded', v_stranded, v_lease_stranded),
    ('fresh', v_fresh, null),
    ('inflight', v_inflight, v_lease_inflight),
    ('targeted', v_targeted, v_lease_targeted),
    ('tpl_stranded', v_tpl_stranded, v_lease_tpl),
    ('tpl_reminder', v_tpl_reminder, null);
end
$v816_fixture$;

-- ----------------------------------------------------------------------------------------------
-- 1  rank — strictly between sent and failed
-- ----------------------------------------------------------------------------------------------
do $v816_t1$
declare v_sent integer; v_unc integer; v_failed integer;
begin
  v_sent := app.support_status_rank_v535('sent');
  v_unc := app.support_status_rank_v535('sent_unconfirmed');
  v_failed := app.support_status_rank_v535('failed');
  if v_unc = 22 and v_sent < v_unc and v_unc < v_failed then
    insert into v816_out values (1, 'sent_unconfirmed ranks strictly between sent and failed',
      'PASS sent=' || v_sent || ' sent_unconfirmed=' || v_unc || ' failed=' || v_failed);
  else
    insert into v816_out values (1, 'sent_unconfirmed ranks strictly between sent and failed',
      'FAIL sent=' || v_sent || ' sent_unconfirmed=' || v_unc || ' failed=' || v_failed
      || '; a late callback could un-quarantine a row, or Meta could never advance it');
  end if;
end
$v816_t1$;

-- ----------------------------------------------------------------------------------------------
-- 2/3  the explicit sweep quarantines the stranded support row, loudly
-- ----------------------------------------------------------------------------------------------
do $v816_t23$
declare
  v_result jsonb; v_row public.support_messages_v530%rowtype; v_audit jsonb;
  v_id uuid; v_lease uuid;
begin
  execute 'reset role';
  select id, lease into v_id, v_lease from v816_fx where label = 'stranded';

  v_result := public.internal_whatsapp_quarantine_expired_sends_v816('worker-v816-sweep', 200);
  select * into v_row from public.support_messages_v530 where id = v_id;

  if v_row.status = 'sent_unconfirmed'
     and v_row.status_rank = app.support_status_rank_v535('sent_unconfirmed')
     and v_row.lease_token is null and v_row.leased_by is null and v_row.lease_until is null
     and v_row.next_attempt_at is null
     and v_row.error_code = 'lease_expired_while_processing'
     and (v_result->>'support')::integer >= 1 then
    insert into v816_out values (2, 'a stranded support row becomes terminal sent_unconfirmed',
      'PASS ' || v_result::text);
  else
    insert into v816_out values (2, 'a stranded support row becomes terminal sent_unconfirmed',
      'FAIL status=' || v_row.status || ' rank=' || v_row.status_rank
      || ' lease=' || coalesce(v_row.lease_token::text, '<null>')
      || ' error_code=' || coalesce(v_row.error_code, '<null>') || ' result=' || v_result::text);
  end if;

  select detail into v_audit from public.audit_log
   where entity = 'support_messages_v530' and entity_id = v_id
     and action = 'whatsapp_send_quarantined_v816'
   order by created_at desc limit 1;

  if v_audit is not null
     and (v_audit->>'lease_token') = v_lease::text
     and (v_audit->>'leased_by') = 'worker-v816-dead'
     and (v_audit->>'quarantined_by') = 'worker-v816-sweep'
     and (v_audit->>'queue') = 'support'
     and (v_audit->>'reason') = 'lease_expired_while_processing'
     and v_audit ? 'lease_until' then
    insert into v816_out values (3, 'the quarantine is audited and names the lease and the worker',
      'PASS ' || v_audit::text);
  else
    insert into v816_out values (3, 'the quarantine is audited and names the lease and the worker',
      'FAIL detail=' || coalesce(v_audit::text, '<no audit row>')
      || '; a message retired without a record is a silent filter');
  end if;
end
$v816_t23$;

-- ----------------------------------------------------------------------------------------------
-- 4/5/6  the claim: never the quarantined row, still the fresh one, never the live lease
-- ----------------------------------------------------------------------------------------------
do $v816_t456$
declare
  v_stranded uuid; v_fresh uuid; v_inflight uuid;
  v_claimed uuid[]; v_status text; v_infl public.support_messages_v530%rowtype;
begin
  execute 'reset role';
  select id into v_stranded from v816_fx where label = 'stranded';
  select id into v_fresh from v816_fx where label = 'fresh';
  select id into v_inflight from v816_fx where label = 'inflight';

  select coalesce(array_agg(c.message_id), array[]::uuid[]) into v_claimed
    from public.internal_support_claim_outbound_v535('worker-v816-claimer', 20, 120) c;

  select status into v_status from public.support_messages_v530 where id = v_stranded;
  if not (v_stranded = any(v_claimed)) and v_status = 'sent_unconfirmed' then
    insert into v816_out values (4, 'the claim never returns a quarantined row',
      'PASS the stranded row stayed sent_unconfirmed and was not leased again');
  else
    insert into v816_out values (4, 'the claim never returns a quarantined row',
      'FAIL claimed=' || v_claimed::text || ' status=' || v_status
      || '; this is the duplicate WhatsApp the owner ruled against');
  end if;

  if v_fresh = any(v_claimed) then
    insert into v816_out values (5, 'a fresh queued row is still claimed',
      'PASS the fix narrows the claim, it does not stop it');
  else
    insert into v816_out values (5, 'a fresh queued row is still claimed',
      'FAIL claimed=' || v_claimed::text || '; ordinary sends stopped working');
  end if;

  select * into v_infl from public.support_messages_v530 where id = v_inflight;
  if not (v_inflight = any(v_claimed))
     and v_infl.status = 'processing'
     and v_infl.lease_token is not null then
    insert into v816_out values (6, 'a live lease is neither quarantined nor stolen',
      'PASS still processing under its own worker''s unexpired lease');
  else
    insert into v816_out values (6, 'a live lease is neither quarantined nor stolen',
      'FAIL status=' || v_infl.status || ' lease=' || coalesce(v_infl.lease_token::text, '<null>')
      || ' claimed=' || v_claimed::text
      || '; the predicate must be "stranded", not "in flight"');
  end if;
end
$v816_t456$;

-- ----------------------------------------------------------------------------------------------
-- 7  a late report on a quarantined row is refused with the stale-lease code
-- ----------------------------------------------------------------------------------------------
do $v816_t7$
declare v_id uuid; v_lease uuid; v_state text := 'no error'; v_status text;
begin
  execute 'reset role';
  select id, lease into v_id, v_lease from v816_fx where label = 'stranded';
  begin
    perform public.internal_support_report_outbound_v535(
      v_id, v_lease, 'sent', 'wamid.v816-late', null, null, null);
  exception when others then v_state := SQLSTATE;
  end;
  select status into v_status from public.support_messages_v530 where id = v_id;

  if v_state = '40001' and v_status = 'sent_unconfirmed' then
    insert into v816_out values (7, 'a late report cannot resurrect a quarantined row',
      'PASS refused 40001 and the row is still sent_unconfirmed');
  else
    insert into v816_out values (7, 'a late report cannot resurrect a quarantined row',
      'FAIL sqlstate=' || v_state || ' status=' || v_status);
  end if;
end
$v816_t7$;

-- ----------------------------------------------------------------------------------------------
-- 8  the template lane behaves identically
-- ----------------------------------------------------------------------------------------------
do $v816_t8$
declare
  v_id uuid; v_lease uuid; v_row public.whatsapp_template_sends_v557%rowtype;
  v_audit jsonb; v_claimed uuid[];
begin
  execute 'reset role';
  select id, lease into v_id, v_lease from v816_fx where label = 'tpl_stranded';
  select * into v_row from public.whatsapp_template_sends_v557 where id = v_id;

  select detail into v_audit from public.audit_log
   where entity = 'whatsapp_template_sends_v557' and entity_id = v_id
     and action = 'whatsapp_send_quarantined_v816'
   order by created_at desc limit 1;

  select coalesce(array_agg(c.message_id), array[]::uuid[]) into v_claimed
    from public.internal_whatsapp_claim_template_sends_v557('worker-v816-claimer', 20, 120) c;

  if v_row.status = 'sent_unconfirmed'
     and v_row.status_rank = app.support_status_rank_v535('sent_unconfirmed')
     and v_row.lease_token is null
     and v_row.last_error_code = 'lease_expired_while_processing'
     and v_audit is not null and (v_audit->>'queue') = 'template'
     and (v_audit->>'lease_token') = v_lease::text
     and (v_audit->>'leased_by') = 'worker-v816-dead'
     and not (v_id = any(v_claimed)) then
    insert into v816_out values (8, 'the template lane quarantines, audits and never re-claims',
      'PASS ' || v_audit::text);
  else
    insert into v816_out values (8, 'the template lane quarantines, audits and never re-claims',
      'FAIL status=' || v_row.status || ' rank=' || v_row.status_rank
      || ' code=' || coalesce(v_row.last_error_code, '<null>')
      || ' audit=' || coalesce(v_audit::text, '<none>')
      || ' claimed=' || v_claimed::text);
  end if;
end
$v816_t8$;

-- ----------------------------------------------------------------------------------------------
-- 9  the targeted quarantine the dispatcher calls when its own report write will not land
-- ----------------------------------------------------------------------------------------------
do $v816_t9$
declare
  v_id uuid; v_lease uuid; v_first jsonb; v_second jsonb;
  v_row public.support_messages_v530%rowtype; v_audit_rows integer;
  v_wrong text := 'no error'; v_other uuid;
begin
  execute 'reset role';
  select id, lease into v_id, v_lease from v816_fx where label = 'targeted';

  v_first := public.internal_whatsapp_quarantine_send_v816(
    'support', v_id, v_lease, 'report_write_failed', 'worker-v816-reporting');
  v_second := public.internal_whatsapp_quarantine_send_v816(
    'support', v_id, v_lease, 'report_write_failed', 'worker-v816-reporting');

  select * into v_row from public.support_messages_v530 where id = v_id;
  select count(*)::integer into v_audit_rows from public.audit_log
   where entity_id = v_id and action = 'whatsapp_send_quarantined_v816';

  if (v_first->>'quarantined') = 'true'
     and (v_second->>'quarantined') = 'false' and (v_second->>'already_terminal') = 'true'
     and v_row.status = 'sent_unconfirmed'
     and v_row.error_code = 'report_write_failed'
     and v_row.lease_token is null
     and v_audit_rows = 1 then
    insert into v816_out values (9, 'the targeted quarantine is terminal and idempotent',
      'PASS first=' || v_first::text || ' second=' || v_second::text);
  else
    insert into v816_out values (9, 'the targeted quarantine is terminal and idempotent',
      'FAIL first=' || v_first::text || ' second=' || v_second::text
      || ' status=' || v_row.status || ' code=' || coalesce(v_row.error_code, '<null>')
      || ' audit_rows=' || v_audit_rows);
  end if;

  -- A worker holding the wrong lease does not get to decide this row's fate.
  select id into v_other from v816_fx where label = 'inflight';
  begin
    perform public.internal_whatsapp_quarantine_send_v816(
      'support', v_other, gen_random_uuid(), 'report_write_failed', 'worker-v816-impostor');
  exception when others then v_wrong := SQLSTATE;
  end;
  if v_wrong = '40001' then
    insert into v816_out values (10, 'a caller without the lease cannot quarantine a live send',
      'PASS refused 40001');
  else
    insert into v816_out values (10, 'a caller without the lease cannot quarantine a live send',
      'FAIL sqlstate=' || v_wrong || '; any worker could retire another worker''s in-flight row');
  end if;
end
$v816_t9$;

-- ----------------------------------------------------------------------------------------------
-- 11  the duplicate cannot return through the enqueue door
-- ----------------------------------------------------------------------------------------------
do $v816_t11$
declare v_appt uuid; v_already boolean;
begin
  execute 'reset role';
  select id into v_appt from v816_fx where label = 'appointment';
  v_already := app.appointment_already_reminded_v581(v_appt);
  if v_already then
    insert into v816_out values (11, 'a quarantined reminder counts as already reminded',
      'PASS the sweep will not enqueue a second reminder for this appointment');
  else
    insert into v816_out values (11, 'a quarantined reminder counts as already reminded',
      'FAIL app.appointment_already_reminded_v581 said false; the reminder sweep would deliver '
      || 'exactly the duplicate this migration exists to stop');
  end if;
end
$v816_t11$;

-- ----------------------------------------------------------------------------------------------
-- 12  ACL — service_role only
-- ----------------------------------------------------------------------------------------------
do $v816_t12$
declare v_bad text;
begin
  execute 'reset role';
  select string_agg(fn, ', ') into v_bad from (
    select n.nspname || '.' || p.proname as fn
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.proname in ('internal_whatsapp_quarantine_expired_sends_v816',
                         'internal_whatsapp_quarantine_send_v816')
       and (not has_function_privilege('service_role', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute'))
  ) bad;
  if v_bad is null then
    insert into v816_out values (12, 'the quarantine RPCs are service_role only',
      'PASS anon and authenticated cannot reach either');
  else
    insert into v816_out values (12, 'the quarantine RPCs are service_role only',
      'FAIL ' || v_bad);
  end if;
end
$v816_t12$;

select seq, step, outcome from v816_out order by seq;

do $v816_gate$
declare v_failed integer; v_count integer;
begin
  select count(*) into v_failed from v816_out where outcome like 'FAIL%';
  select count(*) into v_count from v816_out;
  if v_failed > 0 then
    raise exception 'nestly_v816 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if v_count <> 12 then
    raise exception 'nestly_v816 acceptance: expected 12 assertions, recorded %', v_count
      using errcode = 'XX001';
  end if;
end
$v816_gate$;

rollback;
