\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN READ ONLY;
SELECT (to_regclass('cron.job') IS NOT NULL)::int AS has_cron \gset
\if :has_cron
SELECT (count(*) > 0)::int AS has_unsupported_cron
FROM cron.job
WHERE jobname IS NULL
   OR database <> current_database()
   OR username <> current_user
\gset
\if :has_unsupported_cron
\echo 'Source has unnamed or cross-database/user cron jobs; manual review is required.'
\quit 3
\endif
SELECT format(
  'SELECT cron.schedule(%L, %L, convert_from(decode(%L, ''base64''), ''UTF8''));',
  jobname,
  schedule,
  replace(encode(convert_to(command, 'UTF8'), 'base64'), E'\n', '')
)
FROM cron.job
ORDER BY jobid;
SELECT format(
  'SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = %L), active := false);',
  jobname
)
FROM cron.job
WHERE NOT active
ORDER BY jobid;
\else
SELECT 'cron.job is not installed; source cron export is empty' WHERE false;
\endif
COMMIT;
