-- Rollback-only acceptance for V184 (products vs services).
begin;
do $$
declare v_def text; v_bad integer;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='staff_module_mode_v94';
  if v_def ilike '%p_module=''inventory''%' then
    raise exception 'the inventory kill switch is back: Products is disabled for every business';
  end if;
  -- the other guards must NOT have been removed along with it
  if v_def !~ 'business_workspace_open_v94' or v_def !~ 'can_see_branch'
     or v_def !~ 'effective_platform_module_mode_v94' then
    raise exception 'removing the kill switch also removed a real guard';
  end if;

  -- one published bundle per sector, and the product/service split is in place
  select count(*) into v_bad from (
    select sector_key from public.sector_bundle_versions where status='published'
     group by sector_key having count(*)>1) x;
  if v_bad>0 then raise exception 'a sector has more than one published bundle'; end if;

  if exists(select 1 from public.sector_bundle_versions
             where status='published' and sector_key in ('fnb','retail')
               and 'services'=any(modules)) then
    raise exception 'product-only sectors must not default to services';
  end if;
  if exists(select 1 from public.sector_bundle_versions
             where status='published' and sector_key in ('massage','fitness')
               and 'inventory'=any(modules)) then
    raise exception 'service-only sectors must not default to products';
  end if;
  if not exists(select 1 from public.sector_bundle_versions
                 where status='published' and sector_key='salon'
                   and 'services'=any(modules) and 'inventory'=any(modules)) then
    raise exception 'salon must default to both';
  end if;

  -- the owner override must drop hard dependents, or the dependency resolver undoes it
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_set_sales_mix_v184';
  if v_def !~ 'requires_modules' then
    raise exception 'sales-mix toggle ignores module dependencies and will silently no-op';
  end if;
  if v_def !~ 'a business must sell services, products, or both' then
    raise exception 'sales-mix toggle allows a workspace that sells nothing';
  end if;
end $$;
rollback;
