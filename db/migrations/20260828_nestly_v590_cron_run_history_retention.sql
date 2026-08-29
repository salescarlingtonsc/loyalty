begin;

-- nestly_v590_cron_run_history_retention -- VERBATIM MIRROR of an already-applied production
-- migration (project gadpooereceldfpfxsod, ledger version 20260828135225), recovered
-- read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828135225
--
-- This is the first of two v590 migrations. It schedules the daily cron job that later calls
-- app.purge_cron_run_history_v590(); the function itself is created two minutes afterward by
-- the paired migration nestly_v590_cron_run_history_retention_fn (20260828135527). pg_cron
-- stores cron.job.command as plain text and only resolves it at run time, so scheduling ahead
-- of the function's existence does not error -- the job simply would not have run
-- successfully in the short window between the two migrations.

select cron.schedule('nestly-v590-cron-history-retention', '53 2 * * *',
  $cron$select app.purge_cron_run_history_v590()$cron$);

commit;
