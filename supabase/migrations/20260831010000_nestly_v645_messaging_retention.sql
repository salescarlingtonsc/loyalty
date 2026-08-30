-- NESTLY v645 — Phase B, B2: messaging tables get a PII lifecycle.
-- whatsapp_template_sends_v557, retention_sends_v551, support_messages_v530 and the push
-- delivery tables held rendered parameters, chat bodies, phone numbers and wamids (each
-- decodes to an E.164 number) with NO retention rule. The rule lands while the tables hold
-- single-digit rows. Two stages, owner-approved (DB-1 default accepted: support bodies 180d):
--   redact  — send params/phones/wamids at 90 days (terminal rows only, so the dispatcher and
--             status ingest never lose a live row); support bodies + wamid at 180 days
--   delete  — rows at 400 days (aligned with the v255/v100 horizon; B3's rollups bank the
--             aggregates first)
-- Redaction removes columns attribution never reads (v582's recovery feed uses status/grant
-- linkage only), so every number the product shows is unchanged. Redaction is deliberately
-- irreversible.
begin;

-- The dispatch tables have no append-only guards (they are lease-mutated by design), but
-- their PII columns are NOT NULL in places; drop that so redaction can null them.
alter table public.whatsapp_template_sends_v557
  alter column parameters drop not null,
  alter column recipient_phone_norm drop not null;
alter table public.retention_sends_v551
  alter column variables drop not null,
  alter column recipient_phone_norm drop not null;

create or replace function app.run_messaging_retention_v645()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_redact_557 integer; v_redact_551 integer; v_redact_530 integer;
  v_del_557 integer; v_del_551 integer; v_del_530 integer; v_del_push integer;
begin
  -- Stage 1a: redact terminal send rows at 90 days.
  update public.whatsapp_template_sends_v557 s
     set parameters = null, recipient_phone_norm = null, provider_message_id = null
   where s.status not in ('queued','processing')
     and coalesce(s.sent_at, s.queued_at) < now() - interval '90 days'
     and (s.parameters is not null or s.recipient_phone_norm is not null
          or s.provider_message_id is not null);
  get diagnostics v_redact_557 = row_count;

  update public.retention_sends_v551 s
     set variables = null, recipient_phone_norm = null, provider_message_id = null
   where s.status not in ('queued','processing')
     and coalesce(s.sent_at, s.failed_at, s.queued_at) < now() - interval '90 days'
     and (s.variables is not null or s.recipient_phone_norm is not null
          or s.provider_message_id is not null);
  get diagnostics v_redact_551 = row_count;

  -- Stage 1b: support chat bodies at 180 days (DB-1).
  update public.support_messages_v530 m
     set body = null, rendered_body = null, provider_message_id = null
   where m.occurred_at < now() - interval '180 days'
     and (m.body is not null or m.rendered_body is not null or m.provider_message_id is not null);
  get diagnostics v_redact_530 = row_count;

  -- Stage 2: delete at 400 days.
  delete from public.whatsapp_template_sends_v557
   where coalesce(sent_at, queued_at) < now() - interval '400 days';
  get diagnostics v_del_557 = row_count;
  delete from public.retention_sends_v551
   where coalesce(sent_at, failed_at, queued_at) < now() - interval '400 days';
  get diagnostics v_del_551 = row_count;
  delete from public.support_messages_v530
   where occurred_at < now() - interval '400 days';
  get diagnostics v_del_530 = row_count;
  delete from public.customer_push_deliveries_v95
   where coalesce(completed_at, created_at) < now() - interval '400 days';
  get diagnostics v_del_push = row_count;

  return jsonb_build_object(
    'redacted', jsonb_build_object('v557', v_redact_557, 'v551', v_redact_551, 'v530', v_redact_530),
    'deleted', jsonb_build_object('v557', v_del_557, 'v551', v_del_551, 'v530', v_del_530, 'push', v_del_push));
end;
$$;
revoke all on function app.run_messaging_retention_v645() from public, anon, authenticated;
grant execute on function app.run_messaging_retention_v645() to service_role;

select cron.schedule(
  'nestly-v645-messaging-retention-daily',
  '35 19 * * *',
  $cron$select app.run_messaging_retention_v645();$cron$
);

commit;
