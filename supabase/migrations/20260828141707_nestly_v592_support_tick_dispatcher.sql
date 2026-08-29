begin;

-- nestly_v592_support_tick_dispatcher -- VERBATIM MIRROR of an already-applied production
-- migration (project gadpooereceldfpfxsod, ledger version 20260828141707), recovered
-- read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141707
--
-- Creates app.support_tick_v592(), a single per-minute dispatcher that sequentially runs the
-- inbound router, the dispatch driver and the status-ingest worker, catching each worker's
-- errors independently and writing one SUPPORT_TICK_WORKER_ERROR audit_log row if any failed.
-- Retires the three separate per-minute cron jobs it replaces
-- (nestly-v531-support-inbound-router, nestly-v536-support-dispatch,
-- nestly-v536-support-status-ingest) and schedules the single replacement job
-- nestly-v592-support-tick.

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
$function$;

revoke all on function app.support_tick_v592() from public, anon, authenticated;
grant execute on function app.support_tick_v592() to service_role;

select cron.unschedule('nestly-v531-support-inbound-router');
select cron.unschedule('nestly-v536-support-dispatch');
select cron.unschedule('nestly-v536-support-status-ingest');
select cron.schedule('nestly-v592-support-tick', '* * * * *',
  $cron$select app.support_tick_v592()$cron$);

commit;
