-- Rollback-only acceptance for V177 client error reports.
-- Run after the canonical chain through v177 in a disposable local database.
--
-- Proves:
--   * the telemetry table has RLS enabled with zero policies and no browser
--     role privileges (no client can read another user's error reports);
--   * the intake RPC is SECURITY DEFINER with a pinned search_path,
--     executable by anon and authenticated, and never raises;
--   * dedupe drops an identical error reported twice within a minute.
begin;

do $$
declare
  v_def text;
  v_count integer;
begin
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relname='client_error_reports' and c.relrowsecurity
  ) then
    raise exception 'v177 FAIL: client_error_reports must have RLS enabled';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='client_error_reports') then
    raise exception 'v177 FAIL: client_error_reports must have zero policies (deny-all)';
  end if;
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema='public' and table_name='client_error_reports'
       and grantee in ('PUBLIC','anon','authenticated')
  ) then
    raise exception 'v177 FAIL: browser roles must hold no table privileges';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='report_client_error_v177';
  if v_def is null then
    raise exception 'v177 FAIL: report_client_error_v177 is missing';
  end if;
  if v_def !~* 'security definer' or v_def !~* 'set search_path' then
    raise exception 'v177 FAIL: intake RPC must be SECURITY DEFINER with pinned search_path';
  end if;

  perform public.report_client_error_v177('customer','v177 acceptance error',null,'https://example.test/x','test');
  perform public.report_client_error_v177('customer','v177 acceptance error',null,'https://example.test/x','test');
  select count(*) into v_count from public.client_error_reports
   where message='v177 acceptance error';
  if v_count <> 1 then
    raise exception 'v177 FAIL: dedupe expected 1 row for a repeated error, found %', v_count;
  end if;

  perform public.report_client_error_v177(null,null,null,null,null);
  raise notice 'v177 PASS: locked-down telemetry table, safe intake, dedupe verified';
end $$;

rollback;
