\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'
BEGIN READ ONLY;
SELECT (to_regclass('cron.job') IS NOT NULL)::int AS has_cron \gset
\if :has_cron
SELECT jobid, coalesce(jobname, ''), schedule, database, username, active,
       replace(encode(convert_to(command, 'UTF8'), 'base64'), E'\n', '')
FROM cron.job
ORDER BY jobid;
\else
SELECT 'cron.job is not installed';
\endif
COMMIT;
