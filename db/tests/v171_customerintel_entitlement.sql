-- Rollback-only acceptance for V171 Customer intelligence entitlement.
-- Run after the canonical chain through v171 in a disposable local database.
--
-- Proves:
--   * customerintel is a registered module requiring sales+clients;
--   * every published bundle that carries reports also carries customerintel;
--   * every business whose bundle (or, unassigned, whose own modules) include reports
--     is entitled to customerintel.
begin;

do $$
begin
  if not exists (
    select 1 from public.module_registry
     where module_key='customerintel'
       and requires_modules @> array['sales','clients']
  ) then
    raise exception 'customerintel must be registered requiring sales+clients';
  end if;

  if exists (
    select 1 from public.sector_bundle_versions
     where status='published'
       and 'reports' = any(modules)
       and not ('customerintel' = any(modules))
  ) then
    raise exception 'every published bundle with reports must carry customerintel';
  end if;

  if exists (
    select 1 from public.businesses b
     where 'reports' = any(b.enabled_modules)
       and not ('customerintel' = any(b.enabled_modules))
  ) then
    raise exception 'every reports-entitled business must carry customerintel';
  end if;
end $$;

rollback;
