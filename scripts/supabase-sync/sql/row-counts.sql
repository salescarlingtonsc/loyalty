\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'
BEGIN READ ONLY;
SELECT format(
  'SELECT %L, count(*)::bigint FROM %I.%I;',
  n.nspname || '.' || c.relname,
  n.nspname,
  c.relname
)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname IN ('public', 'auth', 'storage', 'supabase_migrations')
  AND NOT (n.nspname = 'storage' AND c.relname IN ('buckets_vectors', 'vector_indexes'))
ORDER BY n.nspname, c.relname
\gexec
COMMIT;
