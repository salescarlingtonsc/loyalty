-- Run after V156a. The transaction is rollback-only and changes no durable data.
begin;

do $$
declare
  v_preview_config text[];
  v_accept_config text[];
begin
  select proconfig into strict v_preview_config
  from pg_proc
  where oid = 'public.preview_staff_invite(text)'::regprocedure;

  select proconfig into strict v_accept_config
  from pg_proc
  where oid = 'public.accept_invite(text)'::regprocedure;

  if v_preview_config is distinct from array['search_path=pg_catalog, public'] then
    raise exception 'preview_staff_invite search_path is not pinned: %', v_preview_config;
  end if;
  if v_accept_config is distinct from array['search_path=pg_catalog, public'] then
    raise exception 'accept_invite search_path is not pinned: %', v_accept_config;
  end if;

  if has_function_privilege('public', 'public.preview_staff_invite(text)', 'execute')
     or has_function_privilege('public', 'public.accept_invite(text)', 'execute') then
    raise exception 'PUBLIC execute privilege was broadened';
  end if;
  if not has_function_privilege('anon', 'public.preview_staff_invite(text)', 'execute')
     or has_function_privilege('anon', 'public.accept_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.preview_staff_invite(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.accept_invite(text)', 'execute') then
    raise exception 'V151 invite execute privileges changed';
  end if;
end $$;

rollback;
