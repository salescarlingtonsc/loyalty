-- NESTLY v528 - RAW WHATSAPP WEBHOOK RETENTION (7 DAYS)
--
-- Owner ruling 2026-08-26: "Use 7 days for raw webhook payloads. This raw table
-- is diagnostic transport storage, NOT permanent chat history."
--
-- v504 created public.whatsapp_webhook_events and deliberately deferred this:
-- "No retention sweep is defined here because nothing writes to it in production
-- until the owner completes Meta setup; a retention job belongs with the first
-- real traffic." That traffic arrived at 16:38 SGT today - a real Meta-signed
-- inbound message - so the job is now due.
--
-- WHAT IS IN THE ROWS, AND WHY 7 DAYS IS THE RIGHT CEILING.
-- An inbound payload carries the sender's phone number and their message text
-- verbatim. It also carries the wamid - and a wamid is NOT an opaque identifier:
-- `wamid.HBgK<base64>` decodes to a string containing the sender's E.164 number.
-- I confirmed that against the real message. So meta_message_ids is a
-- PDPA-relevant column too, not a harmless key, and a purge that kept "just the
-- ids" would not be a purge.
--
-- Straight DELETE, therefore, with no tombstone. Keeping a redacted husk would
-- imply this table is a history, and the owner's ruling is explicitly that it is
-- not. Conversation history belongs to the support system's own tables, which do
-- not exist yet and will carry their own consent and retention rules.
--
-- SHAPE. Mirrors public.purge_campaign_send_records_v255 (the house retention
-- precedent): bounded limit, ordered oldest-first, `for update skip locked` so a
-- long sweep cannot block ingestion, service_role execute only, and a daily
-- pg_cron job on the established 19:xx UTC / 03:xx SGT convention. 19:25 is the
-- free slot between v310 (19:30) and the v94/v122 cluster.
--
-- INGESTION IS UNAFFECTED. The purge touches only rows whose received_at is
-- older than the window; the webhook writes rows with received_at = now(). The
-- two cannot contend for the same row. Nothing customer-facing reads this table
-- at all - it has RLS on with zero policies and every grant revoked, so no
-- customer and no merchant has ever been able to see a row in it.

begin;

create or replace function public.purge_whatsapp_webhook_events_v528(
  p_limit integer default 5000,
  p_retain_days integer default 7
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_deleted integer := 0;
begin
  if p_limit not between 1 and 10000 then
    raise exception 'purge limit must be 1..10000' using errcode = '22023';
  end if;
  -- A zero or negative window would delete rows the webhook wrote moments ago,
  -- which is how a retention job becomes an outage. The floor is one day.
  if p_retain_days not between 1 and 3650 then
    raise exception 'retention window must be 1..3650 days' using errcode = '22023';
  end if;

  with expired as (
    select event.id
      from public.whatsapp_webhook_events event
     where event.received_at < clock_timestamp() - make_interval(days => p_retain_days)
     order by event.received_at, event.id
     limit p_limit
     for update skip locked
  )
  delete from public.whatsapp_webhook_events target
   using expired
   where target.id = expired.id;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$fn$;

revoke all privileges on function public.purge_whatsapp_webhook_events_v528(integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.purge_whatsapp_webhook_events_v528(integer, integer)
  to service_role;

comment on function public.purge_whatsapp_webhook_events_v528(integer, integer) is
  'v528 retention sweep for the raw Meta webhook inbox. Diagnostic transport storage only, 7-day default window (owner ruling 2026-08-26). Deletes outright: the payload carries the sender MSISDN and message text, and a wamid base64-decodes to the sender number, so a partial purge would not be a purge.';

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    perform cron.schedule(
      'nestly-v528-whatsapp-webhook-retention',
      '25 19 * * *',
      $command$select public.purge_whatsapp_webhook_events_v528(5000, 7)$command$);
  end if;
exception when others then null;  -- pg_cron may be absent in a bare rehearsal db
end $cron$;

commit;
