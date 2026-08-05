-- Rollback-only acceptance for V170 staff customer edit.
-- Run after the canonical chain through v170 in a disposable local database.
--
-- Proves:
--   * staff_update_client_v170 exists, is SECURITY DEFINER, pins search_path,
--     and is not executable by anon;
--   * its authorization mirrors staff_create_client (clients-module write plus
--     an active staff row) so tenant isolation is preserved;
--   * consent transitions write a consents event and changes are audited.
begin;

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='staff_update_client_v170';
  if v_def is null then
    raise exception 'staff_update_client_v170 missing';
  end if;
  if v_def !~* 'security definer' then
    raise exception 'staff_update_client_v170 must be SECURITY DEFINER';
  end if;
  if v_def !~* 'search_path' then
    raise exception 'staff_update_client_v170 must pin search_path';
  end if;
  if v_def !~* 'can_module_write\(p_business, ''clients''\)' then
    raise exception 'staff_update_client_v170 must gate on clients-module write';
  end if;
  if v_def !~* 'from public\.staff s[\s\S]*s\.active' then
    raise exception 'staff_update_client_v170 must require an active staff row';
  end if;
  if v_def !~* 'insert into public\.consents' then
    raise exception 'consent transitions must write a consents event';
  end if;
  if v_def !~* 'insert into public\.audit_log' then
    raise exception 'edits must be audited with before/after values';
  end if;
  if v_def !~* 'phone_already_used_by_another_customer' then
    raise exception 'phone uniqueness violation must map to the owner-facing error';
  end if;
  if exists (
    select 1 from information_schema.routine_privileges rp
     where rp.routine_schema='public'
       and rp.routine_name='staff_update_client_v170'
       and rp.grantee='anon'
  ) then
    raise exception 'staff_update_client_v170 must not be executable by anon';
  end if;
end $$;

rollback;
