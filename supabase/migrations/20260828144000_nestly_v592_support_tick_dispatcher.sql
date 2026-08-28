-- nestly_v592 -- one scheduler for the support lane, three unchanged workers.
--
-- Jobs 32/33/34 (nestly-v531-support-inbound-router, nestly-v536-support-dispatch,
-- nestly-v536-support-status-ingest) each ran `* * * * *` against the same
-- subsystem and the same whatsapp_webhook_events table. With
-- cron.use_background_workers = off each one forks its own OS process and opens
-- its own libpq connection every minute: 4,320 process starts/day for three
-- functions that between them normally find zero work.
--
-- CADENCE IS DELIBERATELY UNCHANGED (`* * * * *`). No customer-visible timing
-- moves. This removes scheduler churn only. The three worker functions are NOT
-- modified here and are NOT merged -- they stay individually callable and
-- individually idempotent.
--
-- FAILURE ISOLATION: each worker runs inside its own BEGIN/EXCEPTION block,
-- which is a subtransaction, so one worker raising cannot roll back or prevent
-- the others. Proven in prod by a rolled-back test that replaced
-- support_route_inbound_v531 with a raising stub: the faulting worker was named
-- in the result, the other two still completed, and an audit row was written.
--
-- ORDERING is the pipeline's natural order -- route inbound, dispatch outbound,
-- then ingest statuses -- which if anything shortens the round trip versus three
-- jobs firing at the same instant and racing.
--
-- OBSERVABILITY TRADE-OFF, STATED PLAINLY: previously a worker raising made
-- cron.job_run_details show that job 'failed'. Now the tick catches it, so the
-- cron row reads 'succeeded' and the failure is recorded in public.audit_log
-- under action 'SUPPORT_TICK_WORKER_ERROR' and returned in the tick's jsonb.
-- This changes WHERE you look for a failure. It is not a loss of signal: the
-- three workers already swallowed their own per-event errors internally
-- (`exception when others then null`), so cron only ever saw catastrophic
-- function-level faults -- which audit_log now captures with the sqlstate and
-- message that cron never recorded.
--
-- ROLLBACK: unschedule 'nestly-v592-support-tick', then re-create the three
-- original schedules:
--   select cron.schedule('nestly-v531-support-inbound-router','* * * * *',
--     $$select app.support_route_inbound_v531(200)$$);
--   select cron.schedule('nestly-v536-support-dispatch','* * * * *',
--     $$select app.v536_run_support_dispatch()$$);
--   select cron.schedule('nestly-v536-support-status-ingest','* * * * *',
--     $$select app.support_ingest_status_v535(200)$$);
-- The worker functions are untouched by this migration, so that restores the
-- previous topology exactly.
--
-- app.support_tick_v592's body is in 20260828_nestly_v591_bodies.sql (extracted
-- from prod in the same pass). This file carries the schedule change only.

begin;

select cron.unschedule('nestly-v531-support-inbound-router');
select cron.unschedule('nestly-v536-support-dispatch');
select cron.unschedule('nestly-v536-support-status-ingest');

select cron.schedule('nestly-v592-support-tick', '* * * * *',
  $cron$select app.support_tick_v592()$cron$);

commit;
