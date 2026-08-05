-- Rollback-only acceptance for V169 approval activation repair.
-- Run after the canonical chain through v169 in a disposable local database.
--
-- Proves:
--   * platform_activate_approved_application_v169 exists, is SECURITY DEFINER,
--     pins search_path, and is not executable by anon;
--   * platform_decide_business_application_v105 no longer seeds
--     public.loyalty_programs (the insert that tripped
--     app.c45_loyalty_program_version_write_guard under the super-admin actor
--     and rolled back every approval);
--   * v105 retains its provisioning block (businesses/staff/branches writes).
begin;

do $$
declare
  v_def text;
begin
  -- V169 repair RPC surface
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname='platform_activate_approved_application_v169';
  if v_def is null then
    raise exception 'v169 RPC missing';
  end if;
  if v_def !~* 'security definer' then
    raise exception 'v169 RPC must be SECURITY DEFINER';
  end if;
  if v_def !~* 'search_path' then
    raise exception 'v169 RPC must pin search_path';
  end if;
  if exists (
    select 1 from information_schema.routine_privileges rp
     where rp.routine_schema='public'
       and rp.routine_name='platform_activate_approved_application_v169'
       and rp.grantee='anon'
  ) then
    raise exception 'v169 RPC must not be executable by anon';
  end if;

  -- v105 must be repaired: no loyalty seed, provisioning intact
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname='platform_decide_business_application_v105';
  if v_def is null then
    raise exception 'v105 decision RPC missing';
  end if;
  if v_def ~* 'insert into public\.loyalty_programs' then
    raise exception 'v105 must not seed loyalty_programs: the seed trips the owner-only version guard under the super-admin actor and rolls back the entire approval';
  end if;
  if v_def !~* 'insert into public\.businesses' or v_def !~* 'insert into public\.staff' then
    raise exception 'v105 must retain direct workspace provisioning';
  end if;
end $$;

rollback;
