-- Rollback-only acceptance for V193: only an UNSOLD package version may be renamed or deleted.
begin;
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_manage_package_plan_v193';
  if v_def is null then raise exception 'business_manage_package_plan_v193 missing'; end if;

  -- the guard must key on plan_id, the real FK — not a name/version snapshot that two versions share
  if v_def !~ 'client_packages' or v_def !~ 'plan_id=p_plan' then
    raise exception 'sold-guard does not check client_packages.plan_id';
  end if;
  if v_def !~ 'create a new version instead' then
    raise exception 'a sold package must be refused with the version route, not silently allowed';
  end if;
  if v_def !~ 'can_module_write' then
    raise exception 'package management is not permission gated';
  end if;
  if v_def !~ 'for update' then
    raise exception 'the plan row is not locked while its purchase count is decided';
  end if;
end $$;

-- package_plans must stay write-closed to the browser: this RPC is the only way in.
do $$
begin
  if exists (select 1 from pg_policy p join pg_class c on c.oid=p.polrelid
              where c.relname='package_plans' and p.polcmd in ('w','d','a')) then
    raise exception 'package_plans gained a direct write policy; the RPC is no longer the only path';
  end if;
end $$;
rollback;
