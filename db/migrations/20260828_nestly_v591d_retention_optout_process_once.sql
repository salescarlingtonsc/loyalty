begin;

-- nestly_v591d_retention_optout_process_once -- VERBATIM MIRROR of an already-applied
-- production migration (project gadpooereceldfpfxsod, ledger version 20260828141416),
-- recovered read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141416
--
-- Fourth of the five v591 migrations. Replaces app.v551_ingest_retention_optout (name predates
-- v591) so it stops re-reading webhook events it has already completed, using the same marker
-- table and retry cap as the other v591 process-once workers. Was previously an unfiltered
-- 2-day rescan; opt-out was already idempotent (the marketing_consent filter means a replay
-- finds nothing left to opt out) but the replay itself is what stops happening here.

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
$function$;

revoke all on function app.v551_ingest_retention_optout(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_optout(integer) to service_role;

commit;
