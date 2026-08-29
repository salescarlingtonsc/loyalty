-- Rollback-only acceptance for nestly_v600 — registering the manually-created
-- nestly-v361-bringback-issue-daily cron job in source (project gadpooereceldfpfxsod).
-- Run: supabase db query --linked -f db/tests/v600_register_v361_bringback_cron.sql
-- Any value starting FAIL is a failure. Nothing is committed.
begin;

create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── 00 baseline: the job may already exist (production does); count before ─
create temp table _before as select count(*)::int as n from cron.job where jobname = 'nestly-v361-bringback-issue-daily';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── 01 run the migration's own guard a first time ───────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'nestly-v361-bringback-issue-daily'
  ) THEN
    PERFORM cron.schedule(
      'nestly-v361-bringback-issue-daily',
      '20 3 * * *',
      $cron$select app.run_bringback_issue_v361();$cron$
    );
  END IF;
END
$$;

insert into _r select '01 the job exists exactly once after the guard runs',
  case when (select count(*) from cron.job where jobname = 'nestly-v361-bringback-issue-daily') = 1
       then 'OK' else 'FAIL: ' || (select count(*) from cron.job where jobname = 'nestly-v361-bringback-issue-daily')::text || ' rows' end;

insert into _r select '02 the schedule is 20 3 * * *',
  case when (select schedule from cron.job where jobname = 'nestly-v361-bringback-issue-daily') = '20 3 * * *'
       then 'OK' else 'FAIL: ' || coalesce((select schedule from cron.job where jobname = 'nestly-v361-bringback-issue-daily'), '<none>') end;

insert into _r select '03 the command calls app.run_bringback_issue_v361()',
  case when (select command from cron.job where jobname = 'nestly-v361-bringback-issue-daily')
            = 'select app.run_bringback_issue_v361();'
       then 'OK' else 'FAIL: ' || coalesce((select command from cron.job where jobname = 'nestly-v361-bringback-issue-daily'), '<none>') end;

insert into _r select '04 the job is active',
  case when (select active from cron.job where jobname = 'nestly-v361-bringback-issue-daily') is true
       then 'OK' else 'FAIL: job is not active' end;

-- ── 05 idempotency: running the guard again on an already-scheduled job is a no-op ─
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'nestly-v361-bringback-issue-daily'
  ) THEN
    PERFORM cron.schedule(
      'nestly-v361-bringback-issue-daily',
      '20 3 * * *',
      $cron$select app.run_bringback_issue_v361();$cron$
    );
  END IF;
END
$$;

insert into _r select '05 the job still exists exactly once after a second guard run',
  case when (select count(*) from cron.job where jobname = 'nestly-v361-bringback-issue-daily') = 1
       then 'OK' else 'FAIL: ' || (select count(*) from cron.job where jobname = 'nestly-v361-bringback-issue-daily')::text || ' rows' end;

insert into _r select '06 app.run_bringback_issue_v361 exists (the function this migration only schedules)',
  case when to_regprocedure('app.run_bringback_issue_v361()') is not null
       then 'OK' else 'FAIL: function missing' end;

select id, value from _r order by id;
rollback;
