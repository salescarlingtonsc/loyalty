-- Rollback-only acceptance for nestly_v582 — a DELIVERED retention WhatsApp becomes
-- an intervention in the existing recovery attribution report.
--   supabase db query --linked -f db/tests/v582_whatsapp_feeds_recovery_attribution.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Fixture: production tenant qa-kaya-toast (38b30e6d-…). The retention flag and the
-- capability grant are flipped INSIDE the transaction and roll back with everything
-- else. Forged wamids all start 'wamid.v582-'. Sends are enqueued through the REAL
-- path (a bring-back grant fires the v551 enqueue trigger); the sent-state stamp is
-- then applied as a fixture UPDATE rather than by leasing a worker, because v582
-- lives entirely downstream of that, in the webhook status ingest.
--
--   01  delivered -> EXACTLY ONE outreach row, channel/source/occurred_at correct
--   02  a send left 'queued', and a send stopped at 'sent', produce NO outreach
--   03  'failed' and 'suppressed' produce NO outreach
--   04  a second, duplicate 'delivered' callback -> still one row
--   05  two different customers delivered -> two rows
--   06  the same customer delivered twice in one SG day -> one row (the table's own
--       UNIQUE (business, client, SG day) rule; the message did not become two
--       interventions because it was sent twice)
--   07  an APPOINTMENT-lane callback (v557 wamid) -> zero outreach rows, and no v557
--       routine references the outreach table at all
--   08  the send-level guard, exercised directly: the recorder invoked a second time
--       for the SAME send on a DIFFERENT SG day still leaves one row. The day key
--       cannot refuse this (two occurred_on values); only the send-level identity can.
--       Verified non-vacuous: removing the guard turns this case red
--   10  the evidence link is NOT a foreign key: a grant whose delivery was recorded
--       can still be deleted. An FK action would UPDATE this immutable table (42501)
--       and make the grant, its campaign and its customer undeletable
--   09  get_recovery_report_v550 EXECUTES for a business that now has outreach and
--       returns its documented shape (it may legitimately report zeros)
--
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _fx(label text primary key, client_id uuid, grant_id uuid, send_id uuid) on commit drop;
create temp sequence _v582_cycle;  -- distinct cycle_key per grant; bringback_grants_v361_cycle_uk is (campaign, client, cycle)

create or replace function pg_temp.v582_biz() returns uuid language sql immutable as $$
  select '38b30e6d-de73-4c2b-a2ca-19b08950896c'::uuid
$$;
grant execute on function pg_temp.v582_biz() to public;

create or replace function pg_temp.as_v582_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v582_user(uuid) to public;

create or replace function pg_temp.v582_owner() returns uuid language sql as $$
  select st.user_id from public.staff st
  where st.business_id = pg_temp.v582_biz()
    and st.role = 'owner' and st.user_id is not null
  order by st.created_at limit 1
$$;

-- a client that passes every v551 per-client gate
create or replace function pg_temp.v582_client(p_name text, p_phone text) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (pg_temp.v582_biz(), p_name, p_phone, true, false) returning id into v_id;
  -- v572 requires explicit marketing-over-WhatsApp consent evidence, separate
  -- from clients.marketing_consent, or every send is suppressed before it queues
  insert into public.consents(business_id, client_id, purpose, channel, action, source)
  values (pg_temp.v582_biz(), v_id, 'marketing', 'whatsapp', 'granted', 'v582_suite');
  return v_id;
end
$$;

-- a bring-back grant; the v551 trigger enqueues its send
create or replace function pg_temp.v582_grant(p_client uuid) returns uuid
language plpgsql as $$
declare v_campaign uuid; v_id uuid;
begin
  select id into v_campaign from public.bringback_campaigns_v361
   where business_id = pg_temp.v582_biz() and name = 'V582 Suite Campaign';
  insert into public.bringback_grants_v361(business_id, campaign_id, client_id, reward_label,
                                           away_days, cycle_key, granted_at)
  values (pg_temp.v582_biz(), v_campaign, p_client, 'a free kopi', 30,
          (current_date - nextval('_v582_cycle')::int)::date, now())
  returning id into v_id;
  return v_id;
end
$$;

-- stamp a queued send as accepted-by-Meta, exactly as report_v551('sent') would
create or replace function pg_temp.v582_stamp_sent(p_send uuid, p_wamid text) returns void
language sql as $$
  update public.retention_sends_v551
     set status = 'sent',
         status_rank = app.v551_retention_status_rank('sent'),
         sent_at = coalesce(sent_at, now()),
         provider_message_id = p_wamid,
         lease_token = null, leased_by = null, lease_until = null, next_attempt_at = null
   where id = p_send
$$;

-- give a still-QUEUED send its wamid without moving its status, so that a
-- subsequent 'sent'/'failed' callback is a real rank ADVANCE. Stamping the row
-- 'sent' first would make those callbacks no-ops and the refusal vacuous.
create or replace function pg_temp.v582_arm(p_send uuid, p_wamid text) returns void
language sql as $$
  update public.retention_sends_v551 set provider_message_id = p_wamid where id = p_send
$$;

-- forge one Meta status callback and run the ingest
create or replace function pg_temp.v582_callback(p_wamid text, p_status text, p_at timestamptz default now())
returns void language plpgsql as $$
declare v_payload jsonb;
begin
  v_payload := jsonb_build_object('entry', jsonb_build_array(jsonb_build_object(
    'id', 'v582-test-waba', 'changes', jsonb_build_array(jsonb_build_object(
      'value', jsonb_build_object('statuses', jsonb_build_array(
        jsonb_build_object('id', p_wamid, 'status', p_status,
                           'timestamp', extract(epoch from p_at)::bigint::text))))))));
  insert into public.whatsapp_webhook_events(payload, payload_sha256, signature_verified)
  values (v_payload, encode(sha256((v_payload::text || p_status || p_wamid || random()::text)::bytea), 'hex'), true);
  perform app.v551_ingest_retention_status(2000);
end
$$;

-- the grant's trigger enqueues the send; it MUST be a separate statement from the
-- read, or the reading scan's snapshot predates the trigger's insert.
create or replace function pg_temp.v582_send_for(p_client uuid) returns uuid
language plpgsql as $$
declare v_grant uuid; v_send uuid;
begin
  v_grant := pg_temp.v582_grant(p_client);
  select id into v_send from public.retention_sends_v551 where grant_id = v_grant;
  return v_send;
end
$$;

create or replace function pg_temp.v582_outreach_count(p_client uuid) returns integer
language sql as $$
  select count(*)::integer from public.attention_outreach_v550
   where business_id = pg_temp.v582_biz() and client_id = p_client
$$;

-- ---------------------------------------------------------------------------------------------
-- 00  fixture: platform gates open so the enqueue trigger produces real 'queued' rows
-- ---------------------------------------------------------------------------------------------
do $$
begin
  execute 'reset role';
  update app.platform_feature_flags set enabled = true
   where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends');
  insert into public.business_capability_grants_v518(business_id, capability_key, enabled)
  values (pg_temp.v582_biz(), 'whatsapp_retention', true)
  on conflict (business_id, capability_key) do update set enabled = true;
  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days)
  values (pg_temp.v582_biz(), 'V582 Suite Campaign', 'a free kopi', 30);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 01  delivered -> exactly one outreach row, with the right labels and the DELIVERY time
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_client uuid; v_send uuid; o public.attention_outreach_v550; n integer;
  v_when timestamptz := now() - interval '3 hours';
begin
  execute 'reset role';
  v_client := pg_temp.v582_client('V582 Delivered', '90005820');
  v_send := pg_temp.v582_send_for(v_client);
  insert into _fx values ('delivered', v_client, null, v_send);
  perform pg_temp.v582_stamp_sent(v_send, 'wamid.v582-delivered');
  perform pg_temp.v582_callback('wamid.v582-delivered', 'delivered', v_when);

  n := pg_temp.v582_outreach_count(v_client);
  select * into o from public.attention_outreach_v550
   where client_id = v_client order by occurred_at limit 1;

  insert into _r values ('01_delivered_writes_one',
    case when n = 1
           and o.channel = 'whatsapp'
           and o.source = 'retention_whatsapp'
           and o.retention_send_id = v_send
           and o.actor is null
           and abs(extract(epoch from (o.occurred_at - v_when))) < 2
           and o.occurred_on = ((v_when at time zone 'Asia/Singapore')::date)
      then 'PASS one row, channel=whatsapp source=retention_whatsapp at the delivery moment'
      else 'FAIL n=' || n || ' row=' || coalesce(to_jsonb(o)::text, 'NONE') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 02  queued, and sent-but-not-delivered, write nothing
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_queued uuid; v_sent_c uuid; v_send uuid; n_q integer; n_s integer; v_status text;
begin
  execute 'reset role';
  v_queued := pg_temp.v582_client('V582 Still Queued', '90005821');
  perform pg_temp.v582_grant(v_queued);           -- left queued, never dispatched

  v_sent_c := pg_temp.v582_client('V582 Sent Only', '90005822');
  v_send := pg_temp.v582_send_for(v_sent_c);
  -- armed but still queued: the 'sent' callback genuinely advances 0 -> 20, so a
  -- 'sent'-threshold implementation WOULD write a row here. Verified: lowering
  -- the threshold to 'sent' turns case 01 red and this case is the one that
  -- would go red for the opposite reason.
  perform pg_temp.v582_arm(v_send, 'wamid.v582-sent-only');
  perform pg_temp.v582_callback('wamid.v582-sent-only', 'sent', now());

  n_q := pg_temp.v582_outreach_count(v_queued);
  n_s := pg_temp.v582_outreach_count(v_sent_c);
  select status into v_status from public.retention_sends_v551 where id = v_send;

  insert into _r values ('02_queued_and_sent_write_nothing',
    case when n_q = 0 and n_s = 0 and v_status = 'sent'
      then 'PASS Meta accepting a payload is not an intervention'
      else 'FAIL queued=' || n_q || ' sent=' || n_s || ' status=' || coalesce(v_status,'?') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 03  failed, and suppressed, write nothing
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_failed uuid; v_supp uuid; v_send uuid; n_f integer; n_p integer; v_status text;
begin
  execute 'reset role';
  v_failed := pg_temp.v582_client('V582 Failed', '90005823');
  v_send := pg_temp.v582_send_for(v_failed);
  perform pg_temp.v582_arm(v_send, 'wamid.v582-failed');
  perform pg_temp.v582_callback('wamid.v582-failed', 'sent', now());
  perform pg_temp.v582_callback('wamid.v582-failed', 'failed', now());
  select status into v_status from public.retention_sends_v551 where id = v_send;

  -- a suppressed send never acquires a wamid; consent withheld is the cleanest
  -- cause (no consents row is written for this one)
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (pg_temp.v582_biz(), 'V582 Suppressed', '90005824', false, false) returning id into v_supp;
  perform pg_temp.v582_grant(v_supp);

  n_f := pg_temp.v582_outreach_count(v_failed);
  n_p := pg_temp.v582_outreach_count(v_supp);

  insert into _r values ('03_failed_and_suppressed_write_nothing',
    case when n_f = 0 and n_p = 0 and v_status = 'failed'
      then 'PASS a message that did not arrive is not an intervention'
      else 'FAIL failed=' || n_f || ' suppressed=' || n_p || ' status=' || coalesce(v_status,'?') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 04  a duplicate delivered callback, and a full re-ingest, leave one row
-- ---------------------------------------------------------------------------------------------
do $$
declare v_client uuid; n integer; v_ids integer;
begin
  execute 'reset role';
  select client_id into v_client from _fx where label = 'delivered';
  perform pg_temp.v582_callback('wamid.v582-delivered', 'delivered', now() - interval '3 hours');
  perform pg_temp.v582_callback('wamid.v582-delivered', 'delivered', now());
  perform app.v551_ingest_retention_status(2000);   -- re-ingest the whole 2-day window
  n := pg_temp.v582_outreach_count(v_client);
  select count(distinct id)::integer into v_ids from public.attention_outreach_v550 where client_id = v_client;
  insert into _r values ('04_duplicate_callbacks_idempotent',
    case when n = 1 and v_ids = 1
      then 'PASS repeat callbacks and a re-ingest add nothing'
      else 'FAIL n=' || n end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 05  two different customers -> two rows
-- ---------------------------------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; s_a uuid; s_b uuid; n integer;
begin
  execute 'reset role';
  v_a := pg_temp.v582_client('V582 Pair A', '90005825');
  v_b := pg_temp.v582_client('V582 Pair B', '90005826');
  s_a := pg_temp.v582_send_for(v_a);
  s_b := pg_temp.v582_send_for(v_b);
  perform pg_temp.v582_stamp_sent(s_a, 'wamid.v582-pair-a');
  perform pg_temp.v582_stamp_sent(s_b, 'wamid.v582-pair-b');
  perform pg_temp.v582_callback('wamid.v582-pair-a', 'delivered', now());
  perform pg_temp.v582_callback('wamid.v582-pair-b', 'delivered', now());
  n := pg_temp.v582_outreach_count(v_a) + pg_temp.v582_outreach_count(v_b);
  insert into _r values ('05_two_customers_two_rows',
    case when pg_temp.v582_outreach_count(v_a) = 1 and pg_temp.v582_outreach_count(v_b) = 1
      then 'PASS one row each; idempotency is per send, not global'
      else 'FAIL total=' || n end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 06  the SAME customer delivered twice in one SG day -> one row
--     This is the TABLE'S OWN rule, not v582's: UNIQUE (business_id, client_id,
--     occurred_on) says a customer receives at most one recorded intervention per
--     Singapore day, whatever route it arrived by. The second send is a real,
--     separately-identified send; it simply does not earn a second intervention.
-- ---------------------------------------------------------------------------------------------
do $$
declare v_client uuid; s1 uuid; s2 uuid; n integer; v_linked integer;
begin
  execute 'reset role';
  v_client := pg_temp.v582_client('V582 Twice Today', '90005827');
  s1 := pg_temp.v582_send_for(v_client);
  perform pg_temp.v582_stamp_sent(s1, 'wamid.v582-twice-1');
  perform pg_temp.v582_callback('wamid.v582-twice-1', 'delivered', now() - interval '2 hours');

  -- a genuinely second send row for the same client on the same day: a second
  -- grant enqueues a second send. v551's own cooldown may park it as suppressed;
  -- we force it back to queued because the point under test is the OUTREACH rule,
  -- not the cooldown.
  s2 := pg_temp.v582_send_for(v_client);
  update public.retention_sends_v551
     set status = 'queued', status_rank = app.v551_retention_status_rank('queued'),
         suppressed_reason = null
   where id = s2;
  perform pg_temp.v582_stamp_sent(s2, 'wamid.v582-twice-2');
  perform pg_temp.v582_callback('wamid.v582-twice-2', 'delivered', now());

  n := pg_temp.v582_outreach_count(v_client);
  select count(*)::integer into v_linked from public.attention_outreach_v550
   where client_id = v_client and retention_send_id = s1;
  insert into _r values ('06_same_customer_same_day_one_row',
    case when n = 1 and v_linked = 1
      then 'PASS one intervention per customer per SG day (the table''s own rule); the first send holds it'
      else 'FAIL n=' || n || ' linked_to_first=' || v_linked end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 07  the APPOINTMENT lane cannot reach the outreach table
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_before integer; v_after integer; v_refs integer;
begin
  execute 'reset role';
  select count(*)::integer into v_before from public.attention_outreach_v550
   where business_id = pg_temp.v582_biz();

  -- a transactional appointment send, carrying a wamid that matches no retention send
  perform pg_temp.v582_callback('wamid.v582-appointment-reminder', 'delivered', now());
  perform pg_temp.v582_callback('wamid.v582-appointment-reminder', 'read', now());

  select count(*)::integer into v_after from public.attention_outreach_v550
   where business_id = pg_temp.v582_biz();

  -- and no v557 routine mentions the table, so there is no second door either
  select count(*)::integer into v_refs
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app','public')
     and p.prosrc like '%whatsapp_template_sends_v557%'
     and p.prosrc like '%attention_outreach_v550%';

  insert into _r values ('07_appointment_lane_writes_nothing',
    case when v_after = v_before and v_refs = 0
      then 'PASS a transactional wamid matches no retention send; no v557 routine touches the table'
      else 'FAIL before=' || v_before || ' after=' || v_after || ' v557_refs=' || v_refs end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 08  the send-level guard is what bounds a SECOND recorder call
--     The ingest's edge-trigger (record only on the transition from below-delivered
--     to delivered-or-better) already absorbs delivered-then-read on its own, so
--     that path cannot test this layer. Here the recorder is called directly a
--     second time, dated on a DIFFERENT Singapore day, which is exactly the case
--     the table's UNIQUE (business, client, occurred_on) key is powerless against.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_client uuid; v_send uuid; n integer; v_days integer; v_second boolean;
  v_other_day timestamptz;
begin
  execute 'reset role';
  select client_id, send_id into v_client, v_send from _fx where label = 'delivered';
  v_other_day := (select occurred_at from public.attention_outreach_v550
                   where retention_send_id = v_send) - interval '2 days';

  v_second := app.v582_record_retention_outreach(v_send, v_other_day);

  n := pg_temp.v582_outreach_count(v_client);
  select count(distinct occurred_on)::integer into v_days from public.attention_outreach_v550
   where client_id = v_client;
  insert into _r values ('08_send_level_guard_bounds_second_call',
    case when v_second = false and n = 1 and v_days = 1
      then 'PASS a second call on another SG day is refused by the send-level identity'
      else 'FAIL inserted=' || v_second || ' n=' || n || ' distinct_days=' || v_days end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 09  the report still RUNS for a business that now has outreach, and keeps its shape.
--     Zeros are a legitimate answer here — these fixture clients have no qualifying
--     sale history, so nothing should be attributed. We assert the contract, not revenue.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  p jsonb; v_err text := 'no error'; v_rows integer;
begin
  execute 'reset role';
  select count(*)::integer into v_rows from public.attention_outreach_v550
   where business_id = pg_temp.v582_biz();
  begin
    perform pg_temp.as_v582_user(pg_temp.v582_owner());
    p := public.get_recovery_report_v550(pg_temp.v582_biz(),
           (now() at time zone 'Asia/Singapore')::date - 90,
           (now() at time zone 'Asia/Singapore')::date + 1);
  exception when others then v_err := SQLSTATE || ' ' || SQLERRM;
  end;
  execute 'reset role';
  insert into _r values ('09_recovery_report_still_runs',
    case when v_err = 'no error' and v_rows > 0
           and p ? 'window' and p ? 'interventions' and p ? 'returned'
           and p ? 'recovered' and p ? 'baseline' and p ? 'net'
           and p ? 'low_confidence' and p ? 'monthly'
           and (p->'interventions') ? 'messages'
           and (p->'net') ? 'cents'
           and (p->'net'->>'method') = 'gross scaled by (1 - baseline_rate / treated_rate), floored at zero'
      then 'PASS report executes over ' || v_rows || ' outreach rows and returns its documented shape'
      else 'FAIL err=' || v_err || ' outreach_rows=' || v_rows || ' out=' || coalesce(p::text,'null') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 10  the upstream delete path stays open
--     retention_send_id is a plain uuid, not an FK. With `on delete set null` it
--     would fire the v550 immutability trigger through the cascade and refuse the
--     delete with 42501 — measured, not assumed. This case is what keeps it plain.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_client uuid; v_send uuid; v_grant uuid; v_err text := 'no error'; v_fks integer; v_left integer;
begin
  execute 'reset role';
  select client_id, send_id into v_client, v_send from _fx where label = 'delivered';
  select grant_id into v_grant from public.retention_sends_v551 where id = v_send;
  select count(*)::integer into v_fks from pg_constraint
   where conrelid = 'public.attention_outreach_v550'::regclass and contype = 'f'
     and conkey = array[(select attnum from pg_attribute
                          where attrelid = 'public.attention_outreach_v550'::regclass
                            and attname = 'retention_send_id')];
  begin
    delete from public.bringback_grants_v361 where id = v_grant;
  exception when others then v_err := SQLSTATE || ' ' || SQLERRM;
  end;
  select count(*)::integer into v_left from public.attention_outreach_v550 where client_id = v_client;
  insert into _r values ('10_evidence_link_is_not_an_fk',
    case when v_fks = 0 and v_err = 'no error' and v_left = 1
      then 'PASS the grant deletes cleanly; the outreach row outlives its send'
      else 'FAIL fks=' || v_fks || ' delete=' || v_err || ' rows_left=' || v_left end);
end $$;

select k, v from _r order by k;

rollback;
