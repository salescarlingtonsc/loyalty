\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN READ ONLY;
SELECT 'server_version_num=' || current_setting('server_version_num');
SELECT 'database_size=' || pg_database_size(current_database());
SELECT 'extension=' || extname || ':' || extversion FROM pg_extension ORDER BY extname;
SELECT 'schema=' || nspname
FROM pg_namespace
WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
ORDER BY nspname;
COMMIT;
