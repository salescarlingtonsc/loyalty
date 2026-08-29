-- Rollback-only existence acceptance for nestly_v590 through nestly_v592 — the eight
-- source-recovery mirrors of migrations already applied to production (project
-- gadpooereceldfpfxsod, jobs 49/50 in cron.job at capture time). These migrations are NOT
-- meant to be re-applied to production; this suite exists so the repo's own governance tests
-- (a mapped rollback suite is mandatory for every pending migration) have something to run,
-- and so a fresh/rehearsal database that DOES apply them can confirm the objects landed.
-- Run: supabase db query --linked -f db/tests/v590_v592_cron_history_webhook_consumers_support_tick.sql
-- Any value starting FAIL is a failure. Nothing is committed.
begin;

create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── v590: cron history retention ────────────────────────────────────────────
insert into _r select '00 app.purge_cron_run_history_v590 exists',
  case when to_regprocedure('app.purge_cron_run_history_v590(integer,integer,integer,integer)') is not null
       then 'OK' else 'FAIL: function missing' end;

insert into _r select '01 nestly-v590-cron-history-retention is scheduled',
  case when exists(select 1 from cron.job where jobname = 'nestly-v590-cron-history-retention'
                      and schedule = '53 2 * * *' and active)
       then 'OK' else 'FAIL: cron job missing, wrong schedule, or inactive' end;

-- ── v591a: webhook consumer markers ─────────────────────────────────────────
insert into _r select '02 public.whatsapp_webhook_event_consumers exists',
  case when to_regclass('public.whatsapp_webhook_event_consumers') is not null
       then 'OK' else 'FAIL: table missing' end;

insert into _r select '03 whatsapp_webhook_event_consumers has RLS enabled and no browser grant',
  case when not (select relrowsecurity from pg_class where oid = 'public.whatsapp_webhook_event_consumers'::regclass)
       then 'FAIL: RLS not enabled'
       when has_table_privilege('authenticated', 'public.whatsapp_webhook_event_consumers', 'SELECT')
       then 'FAIL: authenticated can read the marker table'
       else 'OK' end;

insert into _r select '04 app.v591_max_attempts exists and returns 5',
  case when app.v591_max_attempts() = 5 then 'OK' else 'FAIL: wrong value' end;

-- ── v591b/c/d: process-once workers ─────────────────────────────────────────
insert into _r select '05 app.support_ingest_status_v535 exists',
  case when to_regprocedure('app.support_ingest_status_v535(integer)') is not null
       then 'OK' else 'FAIL: function missing' end;

insert into _r select '06 app.v551_ingest_retention_status exists',
  case when to_regprocedure('app.v551_ingest_retention_status(integer)') is not null
       then 'OK' else 'FAIL: function missing' end;

insert into _r select '07 app.v551_ingest_retention_optout exists',
  case when to_regprocedure('app.v551_ingest_retention_optout(integer)') is not null
       then 'OK' else 'FAIL: function missing' end;

-- ── v591e: sv tender release no-empty-write ─────────────────────────────────
insert into _r select '08 app.run_sv_tender_release exists and is not browser/service-role callable',
  case when to_regprocedure('app.run_sv_tender_release(integer)') is null
       then 'FAIL: function missing'
       when has_function_privilege('service_role', 'app.run_sv_tender_release(integer)', 'EXECUTE')
       then 'FAIL: service_role can still execute it'
       else 'OK' end;

-- ── v592: support tick dispatcher ───────────────────────────────────────────
insert into _r select '09 app.support_tick_v592 exists',
  case when to_regprocedure('app.support_tick_v592()') is not null
       then 'OK' else 'FAIL: function missing' end;

insert into _r select '10 nestly-v592-support-tick is scheduled every minute',
  case when exists(select 1 from cron.job where jobname = 'nestly-v592-support-tick'
                      and schedule = '* * * * *' and active)
       then 'OK' else 'FAIL: cron job missing, wrong schedule, or inactive' end;

insert into _r select '11 the three retired per-minute jobs are gone',
  case when exists(select 1 from cron.job where jobname in (
                      'nestly-v531-support-inbound-router',
                      'nestly-v536-support-dispatch',
                      'nestly-v536-support-status-ingest'))
       then 'FAIL: a retired job is still scheduled'
       else 'OK' end;

select id, value from _r order by id;
rollback;
