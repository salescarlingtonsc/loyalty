-- V184 — products vs services: kernel unblock, sector defaults, owner override.
-- APPLIED TO PRODUCTION 2026-08-06 via MCP apply_migration in four parts
-- (nestly_v184_inventory_follows_entitlement, nestly_v184b_sector_product_service_defaults,
--  nestly_v184c_owner_sales_mix_toggle, nestly_v184d_sales_mix_dependency_aware).
--
-- Owner: "some business is products only no services (like chicken rice shop or cafe (F&B))
-- while some other shops only have services like massage shop. some have mix like salon (so we
-- can have default for the sectors but able to off or on if needed to)."
--
-- 1. KERNEL. app.staff_module_mode_v94 opened with
--       if not app.business_workspace_open_v94(p_business) or p_module='inventory'
--    so Products/Inventory returned 'disabled' for every business, every role, always —
--    regardless of enabled_modules, the sector bundle or ownership. No product-selling business
--    could record what it actually sells. Only that hardcoded module name is removed; the
--    workspace guard, staff-row requirement, branch visibility, platform override and per-staff
--    allowlist all still apply.
--
-- 2. SECTOR DEFAULTS. Every sector shipped BOTH services and inventory, so a chicken rice shop
--    was asked to define services it does not have. New published bundles:
--       fnb, retail          -> products only
--       massage, fitness     -> services only
--       facial, salon, other -> both (unchanged; these genuinely sell product alongside
--                               treatments, and 'other' is the unknown-sector fallback)
--    sector_bundle_versions allows one published bundle per sector, so the incumbent is retired
--    in the same transaction. Existing assignments keep pointing at their assigned bundle: no
--    live tenant silently loses a module it may be using.
--
-- 3. OWNER OVERRIDE. businesses.enabled_modules is locked by
--    app.business_sector_modules_guard_v75 whenever a sector is assigned, which made "do I sell
--    services or products?" a support ticket. business_set_sales_mix_v184 exposes exactly those
--    two toggles and nothing else, so the sector still governs everything with billing meaning.
--    Turning both off is refused — such a workspace has nothing to record a sale against.
--
--    CAUGHT BY VERIFICATION: the first version silently did nothing. app.business_modules_
--    dependency_guard rewrites enabled_modules through app.resolve_module_dependencies on every
--    write, and module_registry says packages REQUIRES services — so removing services was
--    immediately undone. The RPC now drops hard dependents in the same write and returns them
--    in also_disabled so the owner is told, not surprised.
--
-- VERIFIED against production inside rolled-back transactions on 2026-08-06:
--   the inventory kill switch is gone while every other guard remains; a direct write to
--   enabled_modules is still refused by the sector guard; the sanctioned path turns a firm into
--   products-only (services=false, inventory=true) with packages correctly removed alongside.
begin;

create or replace function app.staff_module_mode_v94(p_business uuid, p_branch uuid, p_module text)
returns text
language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare v_staff public.staff%rowtype;v_platform text;v_staff_mode text;
begin
  if not app.business_workspace_open_v94(p_business) then
    return 'disabled';
  end if;
  select * into v_staff from public.staff staff_row
   where staff_row.business_id=p_business and staff_row.user_id=auth.uid() and staff_row.active
   order by case when staff_row.role='owner' then 0 else 1 end, staff_row.created_at, staff_row.id
   limit 1;
  if not found then return 'disabled';end if;
  if p_branch is not null and not app.can_see_branch(p_business,p_branch) then
    return 'disabled';
  end if;
  select resolved.mode into v_platform
    from app.effective_platform_module_mode_v94(p_business,p_branch,p_module) resolved;
  if coalesce(v_platform,'disabled')='disabled' then return 'disabled';end if;
  if v_staff.role='owner' then return v_platform;
  elsif v_staff.module_perms is not null then
    v_staff_mode:=coalesce(v_staff.module_perms->>p_module,'disabled');
  elsif v_staff.modules is null or p_module=any(v_staff.modules) then v_staff_mode:='rw';
  else v_staff_mode:='disabled';
  end if;
  if v_staff_mode='disabled' then return 'disabled';end if;
  if v_platform='r' or v_staff_mode='r' then return 'r';end if;
  return 'rw';
end
$function$;

commit;
