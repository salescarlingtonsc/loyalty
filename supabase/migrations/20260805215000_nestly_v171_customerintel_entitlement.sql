-- V171: Customer intelligence rides with Reports (owner decision 2026-08-06).
-- APPLIED TO PRODUCTION 2026-08-05/06 via MCP apply_migration (nestly_v171_customerintel_entitlement).
-- The surface was fully built but never registered as a module, so no bundle or tenant could
-- carry it and the V170 un-hiding alone could not make it reachable. Order matters: registry
-- first (the dependency guard validates against it), then published bundles, then per-business
-- resync via the same app.sector_entitlement_sync GUC the platform assignment functions use
-- (business_sector_modules_guard_v75 enforces bundle fidelity for any other writer).
begin;

insert into public.module_registry(module_key, label, requires_modules, recommended_modules, sort_order)
values ('customerintel', 'Customer intelligence', array['sales','clients'], array['reports'], 175)
on conflict (module_key) do nothing;

update public.sector_bundle_versions
   set modules = array_append(modules, 'customerintel')
 where status = 'published'
   and 'reports' = any(modules)
   and not ('customerintel' = any(modules));

do $$
declare
  r record;
begin
  for r in
    select b.id, bundle.modules
      from public.businesses b
      join public.business_sector_assignments assignment on assignment.business_id = b.id
      join public.sector_bundle_versions bundle on bundle.id = assignment.bundle_version_id
     where 'customerintel' = any(bundle.modules)
       and not ('customerintel' = any(b.enabled_modules))
  loop
    perform set_config('app.sector_entitlement_sync', r.id::text, true);
    update public.businesses set enabled_modules = r.modules where id = r.id;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (r.id, null, 'MODULE_ENTITLEMENT_SYNC_V171', 'businesses', r.id,
      jsonb_build_object('module','customerintel','basis','published sector bundle gained customerintel'));
  end loop;
  perform set_config('app.sector_entitlement_sync', '', true);
end $$;

update public.businesses b
   set enabled_modules = array_append(enabled_modules, 'customerintel')
 where 'reports' = any(enabled_modules)
   and not ('customerintel' = any(enabled_modules))
   and not exists (select 1 from public.business_sector_assignments a where a.business_id = b.id);

commit;
