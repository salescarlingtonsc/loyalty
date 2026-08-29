begin;

-- nestly_v591b_support_status_ingest_process_once -- VERBATIM MIRROR of an already-applied
-- production migration (project gadpooereceldfpfxsod, ledger version 20260828141323),
-- recovered read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141323
--
-- Second of the five v591 migrations. Replaces app.support_ingest_status_v535 (the function's
-- own name predates v591 and carries no v591 suffix) so it claims only webhook events this
-- consumer has not already completed, using the public.whatsapp_webhook_event_consumers marker
-- table created by nestly_v591a_webhook_consumer_markers and the app.v591_max_attempts() retry
-- cap it also created. Was previously an unbounded rescan of every 'statuses' webhook event.

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
$function$;

revoke all on function app.support_ingest_status_v535(integer) from public, anon, authenticated;
grant execute on function app.support_ingest_status_v535(integer) to service_role;

commit;
