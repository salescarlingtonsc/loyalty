\pset tuples_only on
\pset format unaligned
\pset footer off
\pset pager off

/*
  Supabase cutover inventory gate.
  Read-only by design: catalog reads, count(*) queries, and definition fingerprints only.
  No customer rows, auth secrets, object names, function bodies, or raw cron commands are emitted.
*/

with
params as (
  select :'gate_scope'::text as scope,
         :'gate_project_ref'::text as project_ref
),
catalog_namespaces as (
  select n.oid, n.nspname
  from pg_namespace n
  where n.nspname in ('public', 'app', 'supabase_migrations')
),
app_relations as (
  select n.nspname as schema_name,
         c.relname as relation_name,
         c.oid as relation_oid,
         c.relkind,
         c.relowner,
         c.relrowsecurity,
         c.relforcerowsecurity,
         c.relpersistence
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'app')
    and c.relkind in ('r', 'p', 'v', 'm', 'S')
),
extensions_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'extension_name', e.extname,
           'schema_name', n.nspname,
           'version', e.extversion
         ) order by e.extname), '[]'::jsonb) as data
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
),
migration_history_section as (
  select case
    when to_regclass('supabase_migrations.schema_migrations') is null then '[]'::jsonb
    else coalesce(
      ((xpath('/row/payload/text()', query_to_xml(
        $sql$
          select coalesce(
            jsonb_agg(
              to_jsonb(sm) - 'statements' - 'statement' - 'sql'
              order by coalesce(to_jsonb(sm)->>'version', ''), to_jsonb(sm)::text
            ),
            '[]'::jsonb
          )::text as payload
          from supabase_migrations.schema_migrations sm
        $sql$,
        false, true, ''
      )))[1])::text::jsonb,
      '[]'::jsonb
    )
  end as data
),
schemas_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', nspname,
           'owner', pg_get_userbyid(nspowner)
         ) order by nspname), '[]'::jsonb) as data
  from pg_namespace
  where nspname in ('public', 'app', 'supabase_migrations', 'storage', 'realtime', 'cron')
     or (nspname not like 'pg_%' and nspname <> 'information_schema' and nspname like 'graphql%')
),
tables_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', schema_name,
           'table_name', relation_name,
           'relkind', relkind,
           'owner', pg_get_userbyid(relowner),
           'rls_enabled', relrowsecurity,
           'rls_forced', relforcerowsecurity,
           'persistence', relpersistence
         ) order by schema_name, relation_name), '[]'::jsonb) as data
  from app_relations
  where relkind in ('r', 'p', 'S')
),
columns_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', r.schema_name,
           'table_name', r.relation_name,
           'column_name', a.attname,
           'ordinal', a.attnum,
           'data_type', format_type(a.atttypid, a.atttypmod),
           'not_null', a.attnotnull,
           'identity', a.attidentity,
           'generated', a.attgenerated,
           'collation', case when a.attcollation = 0 then null else pg_collation.collname end,
           'default_fingerprint', case when d.adbin is null then null else md5(pg_get_expr(d.adbin, d.adrelid)) end
         ) order by r.schema_name, r.relation_name, a.attnum), '[]'::jsonb) as data
  from app_relations r
  join pg_attribute a on a.attrelid = r.relation_oid
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  left join pg_collation on pg_collation.oid = a.attcollation
  where r.relkind in ('r', 'p', 'v', 'm', 'S')
    and a.attnum > 0
    and not a.attisdropped
),
constraints_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', n.nspname,
           'table_name', c.relname,
           'constraint_name', con.conname,
           'constraint_type', con.contype,
           'definition_fingerprint', md5(pg_get_constraintdef(con.oid, true))
         ) order by n.nspname, c.relname, con.conname), '[]'::jsonb) as data
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'app')
),
indexes_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', n.nspname,
           'table_name', t.relname,
           'index_name', i.relname,
           'is_unique', ix.indisunique,
           'is_primary', ix.indisprimary,
           'is_valid', ix.indisvalid,
           'definition_fingerprint', md5(pg_get_indexdef(ix.indexrelid))
         ) order by n.nspname, t.relname, i.relname), '[]'::jsonb) as data
  from pg_index ix
  join pg_class t on t.oid = ix.indrelid
  join pg_class i on i.oid = ix.indexrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname in ('public', 'app')
),
views_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', schema_name,
           'view_name', relation_name,
           'relkind', relkind,
           'owner', pg_get_userbyid(relowner),
           'security_invoker', coalesce(coalesce((select reloptions from pg_class where oid = relation_oid), array[]::text[]) @> array['security_invoker=true'], false),
           'definition_fingerprint', md5(pg_get_viewdef(relation_oid, true))
         ) order by schema_name, relation_name), '[]'::jsonb) as data
  from app_relations
  where relkind in ('v', 'm')
),
functions_base as (
  select n.nspname as schema_name,
         p.proname as function_name,
         p.oid as function_oid,
         p.proowner,
         p.prokind,
         p.prosecdef,
         p.provolatile,
         p.proparallel,
         p.proleakproof,
         p.proisstrict,
         pg_get_function_identity_arguments(p.oid) as identity_arguments,
         format_type(p.prorettype, null) as return_type,
         l.lanname as language_name,
         (select substring(setting from '^search_path=(.*)$')
          from unnest(coalesce(p.proconfig, array[]::text[])) setting
          where setting like 'search_path=%'
          limit 1) as search_path
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where n.nspname in ('public', 'app')
),
functions_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', schema_name,
           'function_name', function_name,
           'identity_arguments', identity_arguments,
           'return_type', return_type,
           'owner', pg_get_userbyid(proowner),
           'kind', prokind,
           'language', language_name,
           'security_definer', prosecdef,
           'search_path', search_path,
           'volatility', provolatile,
           'parallel', proparallel,
           'leakproof', proleakproof,
           'strict', proisstrict,
           'definition_fingerprint', case when prokind = 'f' then md5(pg_get_functiondef(function_oid)) else null end
         ) order by schema_name, function_name, identity_arguments), '[]'::jsonb) as data
  from functions_base
),
function_execute_grants_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', f.schema_name,
           'function_name', f.function_name,
           'identity_arguments', f.identity_arguments,
           'grantee', case when acl.grantee = 0 then 'public' else pg_get_userbyid(acl.grantee) end,
           'grantor', pg_get_userbyid(acl.grantor),
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         ) order by f.schema_name, f.function_name, f.identity_arguments, acl.privilege_type, acl.grantee), '[]'::jsonb) as data
  from functions_base f
  cross join lateral aclexplode(coalesce((select proacl from pg_proc where oid = f.function_oid), acldefault('f', f.proowner))) acl
  where acl.privilege_type = 'EXECUTE'
),
triggers_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', n.nspname,
           'table_name', c.relname,
           'trigger_name', t.tgname,
           'enabled', t.tgenabled,
           'function_schema', fn_ns.nspname,
           'function_name', fn.proname,
           'definition_fingerprint', md5(pg_get_triggerdef(t.oid, true))
         ) order by n.nspname, c.relname, t.tgname), '[]'::jsonb) as data
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc fn on fn.oid = t.tgfoid
  join pg_namespace fn_ns on fn_ns.oid = fn.pronamespace
  where not t.tgisinternal
    and n.nspname in ('public', 'app')
),
rls_tables_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', schema_name,
           'table_name', relation_name,
           'rls_enabled', relrowsecurity,
           'rls_forced', relforcerowsecurity
         ) order by schema_name, relation_name), '[]'::jsonb) as data
  from app_relations
  where relkind in ('r', 'p')
),
policies_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', n.nspname,
           'table_name', c.relname,
           'policy_name', pol.polname,
           'command', pol.polcmd,
           'permissive', pol.polpermissive,
           'roles', (
             select coalesce(jsonb_agg(case when r = 0 then 'public' else pg_get_userbyid(r) end order by case when r = 0 then 'public' else pg_get_userbyid(r) end), '[]'::jsonb)
             from unnest(pol.polroles) r
           ),
           'using_fingerprint', case when pol.polqual is null then null else md5(pg_get_expr(pol.polqual, pol.polrelid)) end,
           'with_check_fingerprint', case when pol.polwithcheck is null then null else md5(pg_get_expr(pol.polwithcheck, pol.polrelid)) end
         ) order by n.nspname, c.relname, pol.polname), '[]'::jsonb) as data
  from pg_policy pol
  join pg_class c on c.oid = pol.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'app')
),
relation_grants_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', r.schema_name,
           'object_name', r.relation_name,
           'object_kind', r.relkind,
           'grantee', case when acl.grantee = 0 then 'public' else pg_get_userbyid(acl.grantee) end,
           'grantor', pg_get_userbyid(acl.grantor),
           'privilege', acl.privilege_type,
           'grantable', acl.is_grantable
         ) order by r.schema_name, r.relation_name, acl.privilege_type, acl.grantee), '[]'::jsonb) as data
  from app_relations r
  cross join lateral aclexplode(coalesce((select relacl from pg_class where oid = r.relation_oid), acldefault(case when r.relkind = 'S' then 'S' else 'r' end, r.relowner))) acl
),
realtime_publications_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'publication_name', p.pubname,
           'all_tables', p.puballtables,
           'insert', p.pubinsert,
           'update', p.pubupdate,
           'delete', p.pubdelete,
           'truncate', p.pubtruncate,
           'schema_name', pt.schemaname,
           'table_name', pt.tablename
         ) order by p.pubname, pt.schemaname, pt.tablename), '[]'::jsonb) as data
  from pg_publication p
  left join pg_publication_tables pt on pt.pubname = p.pubname
),
cron_definitions_section as (
  select case
    when to_regclass('cron.job') is null then '[]'::jsonb
    else coalesce(
      ((xpath('/row/payload/text()', query_to_xml(
        $sql$
          select coalesce(jsonb_agg(jsonb_build_object(
            'job_id', to_jsonb(j)->>'jobid',
            'job_fingerprint', md5(coalesce(to_jsonb(j)->>'jobname', to_jsonb(j)->>'command', '')),
            'schedule', to_jsonb(j)->>'schedule',
            'command_fingerprint', md5(coalesce(to_jsonb(j)->>'command', '')),
            'database_name', to_jsonb(j)->>'database',
            'username', to_jsonb(j)->>'username',
            'active', coalesce((to_jsonb(j)->>'active')::boolean, true)
          ) order by coalesce(to_jsonb(j)->>'jobname', ''), coalesce(to_jsonb(j)->>'schedule', ''), coalesce(to_jsonb(j)->>'command', '')), '[]'::jsonb)::text as payload
          from cron.job j
        $sql$,
        false, true, ''
      )))[1])::text::jsonb,
      '[]'::jsonb
    )
  end as data
),
table_row_counts_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', schema_name,
           'table_name', relation_name,
           'row_count', (
             (xpath('/row/c/text()', query_to_xml(
               format('select count(*)::bigint as c from %I.%I', schema_name, relation_name),
               false, true, ''
             )))[1]
           )::text::bigint
         ) order by schema_name, relation_name), '[]'::jsonb) as data
  from app_relations
  where relkind in ('r', 'p')
),
auth_user_count_section as (
  select jsonb_build_object(
    'users_table_exists', to_regclass('auth.users') is not null,
    'row_count', case
      when to_regclass('auth.users') is null then null
      else ((xpath('/row/c/text()', query_to_xml('select count(*)::bigint as c from auth.users', false, true, '')))[1])::text::bigint
    end
  ) as data
),
storage_counts_section as (
  select jsonb_build_object(
    'buckets_table_exists', to_regclass('storage.buckets') is not null,
    'objects_table_exists', to_regclass('storage.objects') is not null,
    'bucket_count', case
      when to_regclass('storage.buckets') is null then null
      else ((xpath('/row/c/text()', query_to_xml('select count(*)::bigint as c from storage.buckets', false, true, '')))[1])::text::bigint
    end,
    'object_count', case
      when to_regclass('storage.objects') is null then null
      else ((xpath('/row/c/text()', query_to_xml('select count(*)::bigint as c from storage.objects', false, true, '')))[1])::text::bigint
    end,
    'objects_by_bucket', case
      when to_regclass('storage.objects') is null then '[]'::jsonb
      else coalesce(
        ((xpath('/row/payload/text()', query_to_xml(
          $sql$
            select coalesce(jsonb_agg(jsonb_build_object(
              'bucket_fingerprint', md5(bucket_id),
              'object_count', count
            ) order by bucket_fingerprint), '[]'::jsonb)::text as payload
            from (
              select bucket_id, count(*)::bigint as count
              from storage.objects
              group by bucket_id
            ) buckets
          $sql$,
          false, true, ''
        )))[1])::text::jsonb,
        '[]'::jsonb
      )
    end
  ) as data
)
select jsonb_pretty(jsonb_build_object(
  'kind', 'supabase_cutover_inventory_v1',
  'scope', (select scope from params),
  'project_ref', (select project_ref from params),
  'sections', jsonb_build_object(
    'extensions', (select data from extensions_section),
    'migration_history', (select data from migration_history_section),
    'schemas', (select data from schemas_section),
    'tables', (select data from tables_section),
    'columns', (select data from columns_section),
    'constraints', (select data from constraints_section),
    'indexes', (select data from indexes_section),
    'views', (select data from views_section),
    'functions', (select data from functions_section),
    'function_execute_grants', (select data from function_execute_grants_section),
    'triggers', (select data from triggers_section),
    'rls_tables', (select data from rls_tables_section),
    'policies', (select data from policies_section),
    'grants', (select data from relation_grants_section),
    'realtime_publications', (select data from realtime_publications_section),
    'cron_jobs', (select data from cron_definitions_section)
  ),
  'metrics', jsonb_build_object(
    'table_row_counts', (select data from table_row_counts_section),
    'auth_user_count', (select data from auth_user_count_section),
    'storage_counts', (select data from storage_counts_section)
  )
));
