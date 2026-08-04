-- Run after V158. Rollback-only acceptance for catalogue media projection RPCs.
begin;

do $$
declare
  v_media_config text[];
  v_checkout_config text[];
begin
  select proconfig into strict v_media_config
  from pg_proc
  where oid = 'public.business_get_catalogue_media_versions_v158(uuid)'::regprocedure;

  select proconfig into strict v_checkout_config
  from pg_proc
  where oid = 'public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)'::regprocedure;

  if v_media_config is distinct from array['search_path=pg_catalog, public, app, pg_temp'] then
    raise exception 'business_get_catalogue_media_versions_v158 search_path changed: %', v_media_config;
  end if;
  if v_checkout_config is distinct from array['search_path=pg_catalog, public, app, pg_temp'] then
    raise exception 'business_get_checkout_catalogue_v94 search_path changed: %', v_checkout_config;
  end if;

  if has_function_privilege('public', 'public.business_get_catalogue_media_versions_v158(uuid)', 'execute')
     or has_function_privilege('public', 'public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)', 'execute') then
    raise exception 'PUBLIC execute privilege was broadened for catalogue media functions';
  end if;

  if not has_function_privilege('authenticated', 'public.business_get_catalogue_media_versions_v158(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)', 'execute') then
    raise exception 'authenticated catalogue media execute privilege missing';
  end if;
end $$;

rollback;
