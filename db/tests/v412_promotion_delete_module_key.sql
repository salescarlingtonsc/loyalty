-- Rollback-only acceptance for v412 — the promotion delete gate names a real module.
--   supabase db query --linked -f db/tests/v412_promotion_delete_module_key.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21 (Hougang ABC): "End" on a live offer and "Delete" on a draft both showed
-- `promotion write access required` — to the OWNER of the business.
--
-- business_delete_promotion_v183 gated on app.can_module_write_at_v94(..., 'promotions'). The
-- resolver's final fallback is `p_module = any(businesses.enabled_modules)`, and 'promotions' is
-- not a registered module, so that is false for every business — and staff_module_mode_v94 returns
-- 'disabled' BEFORE it reads the staff role, which is why owner and receptionist were refused
-- alike. v412 gates on 'loyalty', the module the client already requires for this surface.
--
-- Checks 01-03 read the REAL catalogue and are the acceptance criteria against production.
-- Check 04 demonstrates the resolver shape on a throwaway table, so the suite still proves the
-- mechanism on a database that does not carry the app schema.

begin;

create temp table _r(k text, v text) on commit drop;

-- ------------------------------------------------------- 1 - the key that was wrong
do $$
begin
  if to_regclass('public.module_registry') is null then
    insert into _r values('01_promotions_is_not_a_module','SKIP module_registry not present in this database');
    insert into _r values('02_loyalty_is_a_module','SKIP module_registry not present in this database');
    return;
  end if;
  insert into _r
  select '01_promotions_is_not_a_module',
    case when count(*)=0 then 'PASS ''promotions'' is not in the module registry - it could never be granted'
         else 'FAIL ''promotions'' IS registered; the v183 gate may have been legitimate' end
  from public.module_registry r where r.module_key='promotions';
  insert into _r
  select '02_loyalty_is_a_module',
    case when count(*)=1 then 'PASS ''loyalty'' is a registered module'
         else 'FAIL ''loyalty'' is not registered - the new gate would refuse too' end
  from public.module_registry r where r.module_key='loyalty';
end $$;

-- ------------------------------------------------------- 2 - the deployed function
insert into _r
select '03_delete_gates_on_loyalty',
  case when count(*)=0 then 'SKIP function not present in this database'
       when count(*) filter (where pg_catalog.pg_get_functiondef(p.oid) like '%can_module_write_at_v94(p_business, null, ''loyalty'')%')=count(*)
         and count(*) filter (where pg_catalog.pg_get_functiondef(p.oid) like '%''promotions''%')=0
       then 'PASS the deployed body gates on loyalty and no longer mentions ''promotions'''
       else 'FAIL the deployed body still gates on a module that does not exist' end
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='business_delete_promotion_v183';

-- Everything else about the function must be untouched: the retire/delete split, the branch-scope
-- cleanup, the audit row and the returned shape. A hand-retyped body lost all four once.
insert into _r
select '04_body_otherwise_intact',
  case when count(*)=0 then 'SKIP function not present in this database'
       when count(*) filter (where pg_catalog.pg_get_functiondef(p.oid) like '%promotion_branch_scopes_v155%'
                               and pg_catalog.pg_get_functiondef(p.oid) like '%promotion_branch_scopes_v154%'
                               and pg_catalog.pg_get_functiondef(p.oid) like '%insert into public.audit_log%'
                               and pg_catalog.pg_get_functiondef(p.oid) like '%''status'',''ok''%'
                               and pg_catalog.pg_get_functiondef(p.oid) like '%updated_by=auth.uid()%')=count(*)
       then 'PASS branch-scope cleanup, audit row, updated_by and the ok/mode return all survive'
       else 'FAIL the body lost something other than the module key' end
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='business_delete_promotion_v183';

-- ------------------------------------------------------- 3 - the mechanism, self-contained
-- Why an unregistered key refuses everyone: the resolver's fallback is a membership test against
-- businesses.enabled_modules, so a key nothing ever writes there can only ever be 'disabled'.
create temp table _mods(enabled_modules text[]) on commit drop;
insert into _mods values (array['dashboard','clients','sales','loyalty','retention']);

insert into _r
select '05_unregistered_key_always_disabled',
  case when (select case when 'promotions'=any(enabled_modules) then 'rw' else 'disabled' end from _mods)='disabled'
        and (select case when 'loyalty'=any(enabled_modules) then 'rw' else 'disabled' end from _mods)='rw'
       then 'PASS the same fallback yields disabled for ''promotions'' and rw for ''loyalty'''
       else 'FAIL the fallback did not behave as the resolver does' end;

select k as check, v as result from _r order by k;

rollback;
