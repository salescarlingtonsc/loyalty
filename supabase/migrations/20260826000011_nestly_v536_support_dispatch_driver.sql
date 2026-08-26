-- NESTLY v536 - C6 M2: THE DISPATCH DRIVER AND THE STATUS TICK
--
-- v535 built the chokepoint and the queue and left them inert. This wires the
-- pg_net driver and the two cron ticks. It STILL sends nothing, because both
-- gates remain shut: the platform flag whatsapp_outbound is false, and no
-- business holds the whatsapp_support_reply capability. Turning the pilot on is
-- two deliberate acts after this applies, not a side effect of applying it.
--
-- The driver follows app.v282_run_customer_push_dispatch exactly: check that
-- vault and net exist, read the secret inside a begin/exception, and return a
-- NAMED reason rather than raising when anything is missing. A scheduled run
-- that cannot reach the edge function must be diagnosable from
-- cron.job_run_details, not appear as a bare failure.
--
-- TWO TICKS, DELIBERATELY SEPARATE:
--   * the dispatcher moves queued replies OUT to Meta
--   * the status sweep pulls delivery/read callbacks IN
-- They are independent because a stalled dispatcher must not stop delivery
-- receipts arriving for messages already sent, and vice versa. The status sweep
-- also does not compete with v531's inbound router for processing_status - see
-- the note in app.support_ingest_status_v535.

begin;

create or replace function app.v536_run_support_dispatch()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_url text;
  v_secret text;
  v_request bigint;
  v_queued integer;
begin
  select count(*)::integer into v_queued
    from public.support_messages_v530
   where direction = 'outbound'
     and status in ('queued', 'processing')
     and coalesce(next_attempt_at, now()) <= now();

  -- Nothing waiting: do not wake the edge function at all. Unlike the v282 push
  -- dispatcher (whose claim RPC both enqueues AND leases, so it cannot know),
  -- this queue is fully materialised by the chokepoint, so a pending-count of
  -- zero really does mean there is nothing to send.
  if v_queued = 0 then
    return jsonb_build_object('queued', 0, 'dispatch', 'idle');
  end if;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'extensions_unavailable');
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_url using 'v282_supabase_url';
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v156_supabase_url';
    end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v536_whatsapp_dispatch_secret';
  exception when others then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'vault_unavailable');
  end;
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'secret_unconfigured');
  end if;

  -- The header name must match the one index.ts compares in constant time;
  -- changing either side alone locks the dispatcher out with a 401 that looks
  -- exactly like a healthy deployment.
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/whatsapp-send-dispatch', v_secret;

  return jsonb_build_object('queued', v_queued, 'dispatch_request_id', v_request);
end
$fn$;

revoke all privileges on function app.v536_run_support_dispatch()
  from public, anon, authenticated, service_role;
grant execute on function app.v536_run_support_dispatch() to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    perform cron.schedule(
      'nestly-v536-support-dispatch',
      '* * * * *',
      $command$select app.v536_run_support_dispatch()$command$);
    perform cron.schedule(
      'nestly-v536-support-status-ingest',
      '* * * * *',
      $command$select app.support_ingest_status_v535(200)$command$);
  end if;
exception when others then null;
end $cron$;

commit;
