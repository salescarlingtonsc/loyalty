-- ============================================================================
-- nestly_v571 — RETENTION LANE: INERT REPAIR
--
-- OWNER DIRECTIVE 2026-08-28: "Fix the technical defect, but we must not turn
-- that fix into an uncontrolled production activation. The final state must
-- still be: RETENTION WHATSAPP SENDS = IMPOSSIBLE / DISARMED."
--
-- This migration therefore does THREE things and deliberately not a fourth:
--   1. fixes the vault lookup so the driver can reach its edge function
--   2. makes the master kill switch actually kill (it did not)
--   3. turns the master switch OFF
-- It grants no capability, arms no tenant, enqueues nothing, and sends nothing.
--
-- ===========================================================================
-- ROOT CAUSE — THE SAME WRONG CONSTANT, A SECOND TIME
-- ===========================================================================
-- app.v551_run_retention_dispatch resolved the edge-function base URL from
-- vault names 'v282_supabase_url' then 'v156_supabase_url'. This project's
-- vault holds exactly: v176_dispatch_secret, v176_supabase_url,
-- v197_join_qr_secret, v327_member_qr_secret, v536_supabase_url,
-- v536_whatsapp_dispatch_secret. NEITHER name it looked for exists, and there
-- was no fallback, so the driver hit its own guard and returned
-- 'secret_unconfigured' without ever calling net.http_post.
--
-- This is bit-for-bit the defect v539 fixed for the support lane — the one that
-- produced "no whatsapp messages was pushed out". Both lanes inherited the same
-- two names from app.v282_run_customer_push_dispatch, which is itself still
-- broken for the same reason and is DELIBERATELY LEFT BROKEN here (see below).
--
-- ===========================================================================
-- WHY NO NEW VAULT KEY IS CREATED
-- ===========================================================================
-- Owner ruling: "Do not blindly introduce a shared Vault key that could also
-- revive v282 customer push." Creating 'v282_supabase_url' would repair v551
-- AND silently resurrect the v282 push dispatcher, flushing an unreviewed
-- backlog of customer notifications as a side effect of a WhatsApp bugfix.
--
-- So this migration creates NO vault secret. It only changes which EXISTING
-- names v551 reads: v536_supabase_url first (its own lane's name, present),
-- then v176_supabase_url (the project's long-standing name, present). The two
-- v282-era names are removed from v551's list entirely, so a future decision to
-- create them cannot reactivate anything through this path.
--
-- ===========================================================================
-- THE KILL SWITCH DID NOT KILL — SECOND DEFECT, FOUND DURING THE AUDIT
-- ===========================================================================
-- app.platform_feature_flags('whatsapp_retention_sends') gated ENQUEUE only.
-- The dispatch driver never read it. So a row already sitting in the queue
-- would have been dispatched even with the master switch off — the switch
-- stopped new work being created but could not stop work already created.
-- A kill switch that cannot stop an in-flight backlog is not a kill switch.
-- The flag is now the FIRST gate in the driver, before the queue is even
-- counted, and it fails closed with a named reason.
--
-- ===========================================================================
-- WHY THE DRIVER GAINED A DRY-RUN INSTEAD OF A TEST-ONLY BRANCH
-- ===========================================================================
-- The v536 defect survived because the only tests were rolled-back SQL suites
-- and source greps, and neither can execute a function whose last act is an
-- HTTP POST. p_dry_run makes the REAL driver — same gates, same order, same
-- resolution — executable end to end with the POST replaced by a report of
-- what it would have posted. The acceptance suite runs the actual production
-- code path rather than a paraphrase of it, and net.http_request_queue is
-- asserted to gain zero rows while it does.
--
-- It is a genuine operating tool, not scaffolding: an on-call engineer can ask
-- "would retention dispatch right now, and if not why not" without sending.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Target resolution, extracted so it can be tested without HTTP
-- ---------------------------------------------------------------------------
-- Takes the candidate names as parameters (defaulted to the correct ones) for
-- one reason: the acceptance suite can prove the FAIL-CLOSED path by passing
-- names that do not exist, without deleting a live vault row inside a
-- transaction. The defaults are the contract; the parameters are the probe.
--
-- Returns the endpoint but NEVER the secret — only whether one was found.

create or replace function app.v551_dispatch_target_v571(
  p_url_names text[] default array['v536_supabase_url', 'v176_supabase_url'],
  p_secret_name text default 'v536_whatsapp_dispatch_secret'
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_url text;
  v_secret text;
  v_name text;
begin
  if to_regnamespace('vault') is null then
    return jsonb_build_object('ok', false, 'reason', 'vault_unavailable');
  end if;

  begin
    foreach v_name in array coalesce(p_url_names, array[]::text[]) loop
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using v_name;
      exit when coalesce(v_url, '') <> '';
    end loop;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using p_secret_name;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'vault_unavailable');
  end;

  -- Split, not conflated. 'secret_unconfigured' covering both halves is what
  -- turned a one-line misconfiguration into a report that the send path was
  -- broken; a named reason should name the actual missing thing.
  if coalesce(v_url, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'base_url_unconfigured');
  end if;
  if coalesce(v_secret, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'dispatch_secret_unconfigured');
  end if;

  return jsonb_build_object(
    'ok', true,
    'reason', 'ok',
    'secret_present', true,
    'endpoint', rtrim(v_url, '/') || '/functions/v1/whatsapp-retention-dispatch');
end
$fn$;

revoke all on function app.v551_dispatch_target_v571(text[], text)
  from public, anon, authenticated;
grant execute on function app.v551_dispatch_target_v571(text[], text) to service_role;

comment on function app.v551_dispatch_target_v571(text[], text) is
  'v571 resolves the retention edge-function endpoint from Vault. Names are parameters so the acceptance suite can execute the fail-closed path without mutating Vault. Returns the endpoint and whether a dispatch secret exists; never returns the secret itself.';

-- ---------------------------------------------------------------------------
-- 2. The driver — master flag first, split reasons, dry-run
-- ---------------------------------------------------------------------------
-- The zero-argument function is DROPPED rather than left beside the new one.
-- Two overloads reachable as v551_run_retention_dispatch() would be ambiguous,
-- which is exactly how the promotion-finalize twins (PGRST203) blocked every
-- save. Verified before dropping: the only caller anywhere is the cron entry
-- 'nestly-v551-retention-dispatch', whose command `select
-- app.v551_run_retention_dispatch()` still resolves through the default.

drop function if exists app.v551_run_retention_dispatch();

create or replace function app.v551_run_retention_dispatch(p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_target jsonb;
  v_request bigint;
  v_queued integer;
begin
  -- (0) THE KILL SWITCH, FIRST. Before the queue is counted, before Vault is
  -- touched. Marketing-category traffic on a shared number must have exactly
  -- one place an operator can stop it, and it must stop work already queued,
  -- not merely work not yet created.
  if not app.platform_feature_enabled('whatsapp_retention_sends') then
    return jsonb_build_object('dispatch', 'retention_disabled');
  end if;

  select count(*)::integer into v_queued
    from public.retention_sends_v551
   where status in ('queued', 'processing')
     and coalesce(next_attempt_at, now()) <= now();

  if v_queued = 0 then
    return jsonb_build_object('queued', 0, 'dispatch', 'idle');
  end if;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'extensions_unavailable');
  end if;

  v_target := app.v551_dispatch_target_v571();
  if (v_target->>'ok') is distinct from 'true' then
    return jsonb_build_object('queued', v_queued,
      'dispatch', coalesce(v_target->>'reason', 'target_unresolved'));
  end if;

  -- Everything above is the real path. Only the POST is withheld.
  if coalesce(p_dry_run, false) then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'would_dispatch',
      'endpoint', v_target->>'endpoint', 'dry_run', true);
  end if;

  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using v_target->>'endpoint',
          (select decrypted_secret from vault.decrypted_secrets
            where name = 'v536_whatsapp_dispatch_secret' order by created_at desc limit 1);

  return jsonb_build_object('queued', v_queued, 'dispatch_request_id', v_request);
end
$fn$;

-- Restated verbatim from the ACL the dropped function carried.
revoke all on function app.v551_run_retention_dispatch(boolean)
  from public, anon, authenticated;
grant execute on function app.v551_run_retention_dispatch(boolean) to service_role;

comment on function app.v551_run_retention_dispatch(boolean) is
  'v571 retention dispatch driver. Gate order: master flag whatsapp_retention_sends (fails closed, stops an already-queued backlog), then queue depth, then extensions, then Vault target resolution with split reasons. p_dry_run runs every gate and reports the endpoint without POSTing, so the acceptance suite executes the production path with no HTTP.';

-- ---------------------------------------------------------------------------
-- 3. DISARM
-- ---------------------------------------------------------------------------
-- Owner directive: retention sends must remain impossible after this task.
-- The Vault defect was acting as an accidental safety catch; repairing it
-- removes that catch, so the deliberate switch is set to the state the
-- accident was providing. Turning this back on is an explicit owner decision,
-- and per §2 above it now genuinely stops dispatch rather than only enqueue.
--
-- No capability grant is touched: business_capability_grants_v518 rows are
-- another session's data, and with this flag off they cannot produce a send.

update app.platform_feature_flags
   set enabled = false
 where feature_key = 'whatsapp_retention_sends';

commit;
