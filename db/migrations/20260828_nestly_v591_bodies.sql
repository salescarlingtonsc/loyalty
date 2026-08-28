-- nestly_v591 (bodies) -- worker definitions as applied to production
-- 2026-08-28, extracted verbatim from prod via pg_get_functiondef so this file
-- and the live database cannot drift. Read the rationale in
-- 20260828_nestly_v591_webhook_process_once_and_sv_empty_run.sql first.
--
-- The final function in this file, app.support_tick_v592, belongs to nestly_v592
-- and is included here only because it was extracted in the same pass; its
-- schedule change lives in the v592 migration.

begin;

CREATE OR REPLACE FUNCTION app.support_ingest_status_v535(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
  v_hit boolean; v_scanned integer := 0; v_failed integer := 0;
  c_consumer constant text := 'support_status_v535';
begin
  -- v591: claim only events this consumer has not already completed. The v531
  -- router owns processing_status, so it cannot be reused here; the marker
  -- table carries a high-water mark per consumer. entry_kinds is the webhook's
  -- own record of whether the envelope carried statuses at all, so envelopes
  -- that are pure inbound messages are never expanded.
  for v_event in
    select e.*
      from public.whatsapp_webhook_events e
      left join public.whatsapp_webhook_event_consumers c
        on c.event_id = e.id and c.consumer = c_consumer
     where (c.event_id is null
            or (c.processed_at is null and c.attempts < app.v591_max_attempts()))
       and 'statuses' = any(e.entry_kinds)
     order by e.received_at
     limit greatest(p_limit, 1)
  loop
    v_scanned := v_scanned + 1;
    begin
      for v_status in
        select st from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'statuses','[]'::jsonb)) st
      loop
        v_wamid := v_status->>'id';
        v_state := v_status->>'status';
        v_at := to_timestamp((v_status->>'timestamp')::bigint);
        if v_state not in ('sent','delivered','read','failed') then
          v_ignored := v_ignored + 1; continue;
        end if;
        v_rank := app.support_status_rank_v535(v_state);

        update public.support_messages_v530
           set status = v_state, status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(delivered_at, v_at) else delivered_at end,
               read_at      = case when v_state = 'read'      then coalesce(read_at, v_at)      else read_at end,
               failed_at    = case when v_state = 'failed'    then coalesce(failed_at, v_at)    else failed_at end
         where provider_message_id = v_wamid and direction = 'outbound' and status_rank < v_rank;
        v_hit := found;

        if not v_hit then
          update public.whatsapp_template_sends_v557
             set status = v_state, status_rank = v_rank,
                 sent_at = case when v_state = 'sent' then coalesce(sent_at, v_at) else sent_at end
           where provider_message_id = v_wamid and status_rank < v_rank;
          v_hit := found;
        end if;

        if v_hit then v_applied := v_applied + 1; else v_ignored := v_ignored + 1; end if;
      end loop;

      -- Success marker written in the SAME subtransaction as the processing,
      -- so a partial failure leaves no marker and the event is retried.
      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts)
      values (v_event.id, c_consumer, now(), 1)
      on conflict (event_id, consumer) do update
        set processed_at = now(),
            attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = null;
    exception when others then
      v_failed := v_failed + 1;
      -- Recorded, never silently dropped: processed_at stays null so the event
      -- is retried until v591_max_attempts, then remains visible for triage.
      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts, last_error)
      values (v_event.id, c_consumer, null, 1, left(sqlstate || ' ' || sqlerrm, 500))
      on conflict (event_id, consumer) do update
        set attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = left(sqlstate || ' ' || sqlerrm, 500);
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'ignored', v_ignored,
                            'scanned', v_scanned, 'failed', v_failed);
end
$function$
;

CREATE OR REPLACE FUNCTION app.v551_ingest_retention_status(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
  v_send_id uuid; v_prev_rank integer; v_scanned integer := 0; v_failed integer := 0;
  v_reach constant integer := app.v551_retention_status_rank('delivered');
  c_consumer constant text := 'retention_status_v551';
begin
  -- v591: was an unfiltered 2-day rescan on every run. Support and retention
  -- wamids remain disjoint, so the two sweeps still cannot both match one
  -- callback; each now simply stops re-reading what it has already completed.
  for v_event in
    select e.*
      from public.whatsapp_webhook_events e
      left join public.whatsapp_webhook_event_consumers c
        on c.event_id = e.id and c.consumer = c_consumer
     where (c.event_id is null
            or (c.processed_at is null and c.attempts < app.v591_max_attempts()))
       and 'statuses' = any(e.entry_kinds)
     order by e.received_at
     limit greatest(p_limit, 1)
  loop
    v_scanned := v_scanned + 1;
    begin
      for v_status in
        select st from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'statuses','[]'::jsonb)) st
      loop
        v_wamid := v_status->>'id';
        v_state := v_status->>'status';
        v_at := to_timestamp((v_status->>'timestamp')::bigint);
        if v_state not in ('sent','delivered','read','failed') then
          v_ignored := v_ignored + 1; continue;
        end if;
        v_rank := app.v551_retention_status_rank(v_state);

        v_send_id := null; v_prev_rank := null;
        update public.retention_sends_v551 t
           set status = v_state,
               status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(t.delivered_at, v_at) else t.delivered_at end,
               read_at = case when v_state = 'read' then coalesce(t.read_at, v_at) else t.read_at end,
               failed_at = case when v_state = 'failed' then coalesce(t.failed_at, v_at) else t.failed_at end
          from (
            select r.id, r.status_rank as prev_rank
              from public.retention_sends_v551 r
             where r.provider_message_id = v_wamid
             for update
          ) s
         where t.id = s.id
           and s.prev_rank < v_rank
        returning t.id, s.prev_rank into v_send_id, v_prev_rank;

        if found then
          v_applied := v_applied + 1;
          if v_rank >= v_reach and coalesce(v_prev_rank, -1) < v_reach then
            perform app.v582_record_retention_outreach(v_send_id, v_at);
          end if;
        else
          v_ignored := v_ignored + 1;
        end if;
      end loop;

      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts)
      values (v_event.id, c_consumer, now(), 1)
      on conflict (event_id, consumer) do update
        set processed_at = now(),
            attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = null;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts, last_error)
      values (v_event.id, c_consumer, null, 1, left(sqlstate || ' ' || sqlerrm, 500))
      on conflict (event_id, consumer) do update
        set attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = left(sqlstate || ' ' || sqlerrm, 500);
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'ignored', v_ignored,
                            'scanned', v_scanned, 'failed', v_failed);
end
$function$
;

CREATE OR REPLACE FUNCTION app.v551_ingest_retention_optout(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_event record; v_msg jsonb; v_body text; v_from text; v_norm text;
  v_client record; v_optouts integer := 0; v_scanned integer := 0; v_failed integer := 0;
  c_consumer constant text := 'retention_optout_v551';
begin
  -- v591: was an unfiltered 2-day rescan. Opt-out remains over-honouring and
  -- idempotent -- the marketing_consent filter already means a replay finds
  -- nothing left to opt out -- but the replay itself now stops happening.
  -- entry_kinds='messages' is the webhook's own record that the envelope
  -- carried inbound messages at all.
  for v_event in
    select e.*
      from public.whatsapp_webhook_events e
      left join public.whatsapp_webhook_event_consumers c
        on c.event_id = e.id and c.consumer = c_consumer
     where (c.event_id is null
            or (c.processed_at is null and c.attempts < app.v591_max_attempts()))
       and 'messages' = any(e.entry_kinds)
     order by e.received_at
     limit greatest(p_limit, 1)
  loop
    v_scanned := v_scanned + 1;
    begin
      for v_msg in
        select m from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'messages','[]'::jsonb)) m
      loop
        if v_msg->>'type' <> 'text' then continue; end if;
        v_body := lower(btrim(coalesce(v_msg->'text'->>'body', '')));
        if v_body not in ('stop', 'unsubscribe') then continue; end if;
        v_from := coalesce(v_msg->>'from', '');
        v_norm := app.norm_phone(v_from);
        if v_norm is null then continue; end if;

        for v_client in
          select distinct c.id, c.business_id
            from public.clients c
            join public.retention_sends_v551 s
              on s.client_id = c.id and s.business_id = c.business_id
           where c.phone_norm = v_norm
             and coalesce(c.marketing_consent, true)
        loop
          update public.clients set marketing_consent = false where id = v_client.id;
          insert into public.consents(business_id, client_id, channel, action, source)
          values (v_client.business_id, v_client.id, 'whatsapp', 'withdrawn', 'whatsapp_stop_reply');
          update public.retention_sends_v551
             set status = 'suppressed', suppressed_reason = 'customer_opted_out',
                 status_rank = app.v551_retention_status_rank('suppressed'),
                 lease_token = null, leased_by = null, lease_until = null,
                 next_attempt_at = null
           where client_id = v_client.id and business_id = v_client.business_id
             and status in ('queued','processing');
          v_optouts := v_optouts + 1;
        end loop;
      end loop;

      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts)
      values (v_event.id, c_consumer, now(), 1)
      on conflict (event_id, consumer) do update
        set processed_at = now(),
            attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = null;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.whatsapp_webhook_event_consumers(event_id, consumer, processed_at, attempts, last_error)
      values (v_event.id, c_consumer, null, 1, left(sqlstate || ' ' || sqlerrm, 500))
      on conflict (event_id, consumer) do update
        set attempts = public.whatsapp_webhook_event_consumers.attempts + 1,
            last_error = left(sqlstate || ' ' || sqlerrm, 500);
    end;
  end loop;
  return jsonb_build_object('optouts', v_optouts, 'scanned', v_scanned, 'failed', v_failed);
end
$function$
;

CREATE OR REPLACE FUNCTION app.run_sv_tender_release(p_limit integer DEFAULT 1000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_run uuid; v_b uuid; v_done integer := 0; v_failed integer := 0;
begin
  -- v591: the existence probe now runs BEFORE sv_automation_begin(). Previously
  -- every one of the 480 daily runs inserted an sv_automation_runs row and
  -- updated it at finish, whether or not a single hold needed releasing --
  -- 16,254 rows against 16,174 runs. The audit trail for productive runs and
  -- for failures is unchanged; only the no-work case stops writing.
  -- Served by the existing partial index checkout_sv_tenders_active_uk
  -- (business_id, account_id) WHERE status = 'reserved'. No new index.
  if not exists (
    select 1 from public.checkout_sv_tenders t where t.status = 'reserved'
  ) then
    return 0;
  end if;

  v_run := app.sv_automation_begin('sv_tender_release');
  -- Scoped by outstanding work, not by authority: an abandoned hold must be released even if the
  -- business was paused after the hold was taken, or its balance stays stranded.
  for v_b in
    select distinct t.business_id from public.checkout_sv_tenders t
     where t.status = 'reserved'
     order by t.business_id
  loop
    begin
      perform public.sv_release_expired_checkout_tenders(v_b, p_limit);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_b, null, 'SV_AUTOMATION_ERROR', 'sv_automation_runs', v_run, jsonb_build_object(
        'job', 'sv_tender_release', 'sqlstate', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform app.sv_automation_finish(v_run, jsonb_build_object('succeeded', v_done, 'failed', v_failed));
  return v_done;
end $function$
;

CREATE OR REPLACE FUNCTION app.support_tick_v592()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_out jsonb := '{}'::jsonb;
  v_err jsonb := '[]'::jsonb;
begin
  begin
    v_out := v_out || jsonb_build_object('inbound', app.support_route_inbound_v531(200));
  exception when others then
    v_err := v_err || jsonb_build_array(jsonb_build_object(
      'worker','support_route_inbound_v531','sqlstate',sqlstate,'message',sqlerrm));
  end;

  begin
    v_out := v_out || jsonb_build_object('dispatch', app.v536_run_support_dispatch());
  exception when others then
    v_err := v_err || jsonb_build_array(jsonb_build_object(
      'worker','v536_run_support_dispatch','sqlstate',sqlstate,'message',sqlerrm));
  end;

  begin
    v_out := v_out || jsonb_build_object('status', app.support_ingest_status_v535(200));
  exception when others then
    v_err := v_err || jsonb_build_array(jsonb_build_object(
      'worker','support_ingest_status_v535','sqlstate',sqlstate,'message',sqlerrm));
  end;

  if jsonb_array_length(v_err) > 0 then
    insert into public.audit_log(business_id, actor, action, entity, detail)
    values (null, null, 'SUPPORT_TICK_WORKER_ERROR', 'app.support_tick_v592',
            jsonb_build_object('migration','nestly_v592','errors',v_err));
  end if;

  return v_out || jsonb_build_object('errors', v_err);
end
$function$
;

revoke all on function app.support_ingest_status_v535(integer) from public, anon, authenticated;
grant execute on function app.support_ingest_status_v535(integer) to service_role;
revoke all on function app.v551_ingest_retention_status(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_status(integer) to service_role;
revoke all on function app.v551_ingest_retention_optout(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_optout(integer) to service_role;
revoke all on function app.run_sv_tender_release(integer) from public, anon, authenticated;
revoke all on function app.support_tick_v592() from public, anon, authenticated;
grant execute on function app.support_tick_v592() to service_role;

commit;
