begin;

-- nestly_v591c_retention_ingest_process_once -- VERBATIM MIRROR of an already-applied
-- production migration (project gadpooereceldfpfxsod, ledger version 20260828141352),
-- recovered read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141352
--
-- Third of the five v591 migrations. Replaces app.v551_ingest_retention_status (name predates
-- v591) so it stops re-reading webhook events it has already completed, using the same
-- whatsapp_webhook_event_consumers marker table and v591_max_attempts() retry cap as
-- nestly_v591b. Was previously an unfiltered 2-day rescan on every run.

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
$function$;

revoke all on function app.v551_ingest_retention_status(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_status(integer) to service_role;

commit;
