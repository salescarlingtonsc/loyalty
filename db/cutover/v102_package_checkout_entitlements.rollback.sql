-- Nestly v102 operational rollback.
-- This deliberately preserves additive history/snapshot columns and any rows
-- already written through v102. It removes the v102 entry points and restores
-- the pre-v102 browser contracts without deleting customer or audit evidence.

begin;

revoke all on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.use_package_session_v102(uuid,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.business_get_checkout_preferences_v102(uuid)
  from public,anon,authenticated;
revoke all on function public.staff_get_customer_entitlements_v102(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.staff_list_package_entitlements_v102(uuid)
  from public,anon,authenticated;
revoke all on function public.set_gift_card_sales_enabled_v102(uuid,boolean)
  from public,anon,authenticated;
revoke all on function public.set_package_points_policy_v102(uuid,boolean)
  from public,anon,authenticated;
revoke all on function public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean
) from public,anon,authenticated;

drop function if exists public.sell_package_v102(uuid,uuid,uuid,uuid,uuid);
drop function if exists public.use_package_session_v102(uuid,uuid,uuid,text);
drop function if exists public.business_get_checkout_preferences_v102(uuid);
drop function if exists public.staff_get_customer_entitlements_v102(uuid,uuid);
drop function if exists public.staff_list_package_entitlements_v102(uuid);
drop function if exists public.set_gift_card_sales_enabled_v102(uuid,boolean);
drop function if exists public.set_package_points_policy_v102(uuid,boolean);
drop function if exists public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean
);

-- Disable the new issuance gate without replacing the already-proven v70
-- issuance body. This keeps exact replay and stored-value non-overlap intact.
alter table public.businesses
  alter column gift_card_sales_enabled set default true;
update public.businesses set gift_card_sales_enabled=true
where not gift_card_sales_enabled;

drop policy if exists package_plans_read_v102 on public.package_plans;
drop policy if exists pkgplans_all on public.package_plans;
create policy pkgplans_all on public.package_plans
for all to authenticated
using(app.is_salon_member(business_id))
with check(app.is_salon_member(business_id));
grant select,insert,update,delete on table public.package_plans to authenticated;

-- The pre-v102 /4 wrapper delegates to the old /3 core, which does not populate
-- purchase snapshots. Relax only the four v102 NOT NULL additions before
-- restoring /4 so rollback checkout remains operational. Existing snapshot
-- values and every historical row are preserved.
alter table public.client_packages
  alter column plan_name_snapshot drop not null,
  alter column plan_version_snapshot drop not null,
  alter column sessions_snapshot drop not null,
  alter column price_cents_snapshot drop not null;

grant execute on function public.sell_package(uuid,uuid,uuid,uuid)
  to authenticated;
-- v54 already retired the non-idempotent, branchless 3-arg core. A v102
-- rollback must not accidentally reopen that older bypass.
revoke all on function public.sell_package(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.use_package_session(uuid,uuid,text)
  to authenticated;

commit;
