-- NESTLY v539 - THE DISPATCHER WAS LOOKING UP A VAULT NAME THAT DOES NOT EXIST
--
-- ROOT CAUSE of "Peekaa shows the reply but the customer never received it".
--
-- app.v536_run_support_dispatch resolves the edge-function base URL from Vault,
-- trying 'v282_supabase_url' and falling back to 'v156_supabase_url'. NEITHER
-- EXISTS in this project. The vault holds: v176_dispatch_secret,
-- v176_supabase_url, v197_join_qr_secret, v327_member_qr_secret and (correctly)
-- v536_whatsapp_dispatch_secret.
--
-- So the driver hit its own guard --
--     if coalesce(v_url,'')='' or coalesce(v_secret,'')='' then
--       return jsonb_build_object(..., 'dispatch','secret_unconfigured');
-- -- and returned WITHOUT calling net.http_post. The edge function was never
-- invoked, Meta was never contacted, and the message sat at status='queued'
-- with attempt_count=0, provider_message_id NULL and error_code NULL. Every
-- minute, successfully, for sixteen minutes.
--
-- I copied those two secret names from app.v282_run_customer_push_dispatch
-- without checking that they resolve in THIS project. They do not, which means
-- the v282 customer web-push dispatcher has the identical fault and has been
-- returning 'secret_unconfigured' since it shipped. That is reported to the
-- owner separately and deliberately NOT fixed here: giving both functions a
-- working URL in one change would silently flush a backlog of customer push
-- notifications as a side effect of a WhatsApp bugfix.
--
-- THE FIX IS THE LOOKUP ORDER, NOT THE ARCHITECTURE. The driver now tries its
-- own name first, then v176_supabase_url which demonstrably exists, and keeps
-- the legacy pair last so nothing regresses if they are ever created. Every
-- other line is unchanged: same guard, same named reasons, same header, same
-- pending-count short circuit.
--
-- WHY 'secret_unconfigured' WAS STILL THE RIGHT DESIGN. The driver failed
-- closed, said so by name, and never invented a success. The outbound row stayed
-- 'queued' and the UI showed 'queued' -- it did not claim the message had been
-- sent. The defect was a wrong constant, and the honesty of the surrounding
-- machinery is what made it a two-query diagnosis instead of an investigation.

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
  v_name text;
begin
  select count(*)::integer into v_queued
    from public.support_messages_v530
   where direction = 'outbound'
     and status in ('queued', 'processing')
     and coalesce(next_attempt_at, now()) <= now();

  if v_queued = 0 then
    return jsonb_build_object('queued', 0, 'dispatch', 'idle');
  end if;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'extensions_unavailable');
  end if;

  begin
    -- v539: own name first, then the one this project actually has. The legacy
    -- pair stays last so a future environment that does define them still works.
    foreach v_name in array array['v536_supabase_url','v176_supabase_url',
                                  'v282_supabase_url','v156_supabase_url'] loop
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using v_name;
      exit when coalesce(v_url, '') <> '';
    end loop;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v536_whatsapp_dispatch_secret';
  exception when others then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'vault_unavailable');
  end;

  -- Distinguish the two missing halves. 'secret_unconfigured' covering both is
  -- what turned a one-line misconfiguration into a report that the send path was
  -- broken; a named reason should name the actual thing.
  if coalesce(v_url, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'base_url_unconfigured');
  end if;
  if coalesce(v_secret, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'dispatch_secret_unconfigured');
  end if;

  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/whatsapp-send-dispatch', v_secret;

  return jsonb_build_object('queued', v_queued, 'dispatch_request_id', v_request);
end
$fn$;

revoke all privileges on function app.v536_run_support_dispatch()
  from public, anon, authenticated, service_role;
grant execute on function app.v536_run_support_dispatch() to service_role;

commit;
