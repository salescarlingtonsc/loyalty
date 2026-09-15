-- nestly_v974 — the registry reconciles itself, on a switch the owner can throw.
--
-- OWNER, 2026-09-15: "can you run it for me? - approved", on the scheduled reconcile v899 left as
-- a deliberate follow-up.
--
-- WHY THIS WAS HELD BACK UNTIL ASKED. v899 built the reconciling write and pointedly did NOT
-- schedule it. v824 exists because a machine was found running that nobody had switched on — 24
-- businesses carrying wa_* columns they never ticked, appointment triggers firing on every booking,
-- seven failed sends nobody was watching — and the honest close of that ruling was not to add
-- another timer unasked. It has now been asked for, so here it is, built so that the v824 story
-- cannot repeat: the runner reads a platform flag BEFORE it does anything, so the job can be
-- silenced with one UPDATE by somebody who has never heard of pg_cron, without unscheduling
-- anything or deploying a line of code.
--
-- WHAT IT DOES, HOURLY. Calls whatsapp-admin-templates with {"action":"reconcile"}, which asks Meta
-- for its template list and records the answer in whatsapp_template_registry_v551. That is the
-- whole job. It cannot send a message, cannot create a template, and cannot add a row to the send
-- gate — reconcile updates only (v899), and the refusals in planTemplateReconcile (v900/v973) mean
-- a failed or empty read writes nothing at all rather than pausing the lane.
--
-- WHY HOURLY AND NOT EVERY MINUTE. The thing being watched is a human at Meta approving a template,
-- which takes 24-48 hours. One Graph call an hour turns "somebody has to notice and type it in"
-- into "it is right within the hour", and that is the entire gap v898 was opened to close. A
-- minute-by-minute poll would buy nothing and spend 1,440 Graph calls a day to buy it. Offset to
-- :07 so it does not pile onto the top of the hour with everything else.
--
-- WHAT IT DOES NOT DO. It does not wake anything when the flag is off, and it does not retry: a
-- failed hour is simply followed by the next hour, which is the correct backoff for a poll whose
-- subject changes at most twice a day. Nothing here reads or writes the v824 switches.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. the switch, before the machine
-- ---------------------------------------------------------------------------------------------
insert into app.platform_feature_flags (feature_key, enabled)
values ('whatsapp_template_reconcile_cron', true)
on conflict (feature_key) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 2. the runner
-- ---------------------------------------------------------------------------------------------
-- Shaped on app.v536_run_support_dispatch verbatim, including the header name, which must match
-- the one whatsapp-admin-templates compares in constant time — changing either side alone locks
-- the job out with a 401 that looks exactly like a healthy deployment.
create or replace function app.v974_run_template_reconcile()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_url text;
  v_secret text;
  v_request bigint;
begin
  -- The switch is read FIRST, before the vault, before pg_net, before anything observable. This is
  -- the line that makes the job killable by an owner rather than by a deployment.
  if not app.platform_feature_enabled('whatsapp_template_reconcile_cron') then
    return jsonb_build_object('reconcile', 'disabled');
  end if;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('reconcile', 'extensions_unavailable');
  end if;

  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_url using 'v536_supabase_url';
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v282_supabase_url';
    end if;
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v156_supabase_url';
    end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v536_whatsapp_dispatch_secret';
  exception when others then
    return jsonb_build_object('reconcile', 'vault_unavailable');
  end;

  -- Fail CLOSED and namedly. A half-configured poller must not look like an idle one — that is
  -- exactly how v282's push dispatcher sat returning secret_unconfigured every five minutes for
  -- weeks with nobody the wiser.
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return jsonb_build_object('reconcile', 'secret_unconfigured');
  end if;

  execute 'select net.http_post(url := $1, body := ''{"action":"reconcile"}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/whatsapp-admin-templates', v_secret;

  return jsonb_build_object('reconcile', 'requested', 'request_id', v_request);
end
$fn$;

comment on function app.v974_run_template_reconcile() is
  'nestly_v974: hourly poll asking Meta for template statuses and recording them. Gated on the platform flag whatsapp_template_reconcile_cron, which is read before anything else happens.';

revoke all privileges on function app.v974_run_template_reconcile()
  from public, anon, authenticated, service_role;
grant execute on function app.v974_run_template_reconcile() to service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. the schedule
-- ---------------------------------------------------------------------------------------------
-- Same defensive shape as v536/v551: absent pg_cron is not a migration failure, and re-running
-- this migration re-schedules rather than duplicating.
do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    begin
      perform cron.unschedule('nestly-v974-template-reconcile');
    exception when others then null;
    end;
    perform cron.schedule(
      'nestly-v974-template-reconcile',
      '7 * * * *',
      $command$select app.v974_run_template_reconcile()$command$);
  end if;
exception when others then null;
end $cron$;

-- The v824 switches are not this migration's business, and it proves that rather than asserting it.
do $guard$
begin
  if exists (select 1 from app.platform_feature_flags
              where feature_key in ('whatsapp_outbound', 'whatsapp_retention_sends') and enabled) then
    raise exception 'v974: a v824 platform switch is enabled; scheduling a reconcile must not turn sending on';
  end if;
  if not app.platform_feature_enabled('whatsapp_template_reconcile_cron') then
    raise exception 'v974: the reconcile flag must exist and be on after this migration';
  end if;
end $guard$;

commit;
