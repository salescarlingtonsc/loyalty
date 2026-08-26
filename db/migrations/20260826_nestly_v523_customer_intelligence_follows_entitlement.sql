-- nestly_v523 — Customer intelligence stops being switched off by hand.
--
-- WHAT WAS THERE. app.staff_module_perms_at_v115 carried a single unconditional clause:
--
--     case when module_keys.module_key='customerintel' then 'disabled'
--
-- ahead of the override/entitlement resolution every other module goes through. It overrode each
-- tenant's own enabled_modules, so no business could hold the module and no role could reach it —
-- the owner included. The page, its route, its seven RPCs, the nav group entry, the module_registry
-- row and the published sector bundles all remained in place, entitled and unreachable.
--
-- WHY IT WAS THERE, and why it is going. Two owner-attributed decisions one day apart:
--   * nestly_v171 (2026-08-06) "Customer intelligence rides with Reports (owner decision)" —
--     registered the module, appended it to every published bundle carrying 'reports', and
--     resynced every business. That is why tenants still carry the entitlement today.
--   * nestly_v219 (2026-08-07) "customerintel is deliberately left disabled — it is a
--     platform-only surface and the owner has not asked for it."
-- v233 and v246 carried the clause forward unexamined. Owner ruling 2026-08-26, after a
-- pre-enablement audit: finish the module and enable it through normal entitlement if it proves
-- distinct, factual and performant. It did, so this removes the override and lets the module
-- resolve exactly like every other one — a business that is not entitled still does not get it.
--
-- WHAT THE AUDIT ESTABLISHED, so the next reader does not have to redo it. Every figure the screen
-- displays was reconciled against production base tables for Cubbly SPA over 28 Jul – 26 Aug 2026:
-- get_revenue_truth_v106's headline known_revenue 448500 is the same number the Dashboard,
-- Business Insights and the P&L accrual tile show, splitting into identified 445500 + anonymous
-- 3000 (one real walk-in); all eight customer rows tie; ratios with a zero denominator render
-- "Not enough data" rather than a manufactured 0%. Scale was measured for the first time in
-- db/tests/executed/v422_customer_intelligence_scale.sql — 200 businesses, 2,000 customers,
-- 24,000 sales — and is linear, not quadratic.
--
-- THE SECOND CHANGE, and why it belongs in the same migration. The final filter gated only
-- ('expenses','pnl') on view_finance. Both Customer intelligence RPCs — get_revenue_truth_v106 and
-- get_customer_intelligence_v83 — raise 42501 without app.has_perm(business,'view_finance'), which
-- only owner, manager and bookkeeper hold. Removing the override without this would have handed a
-- frontdesk user an entitlement the RPCs then refuse: a module visible in the rail that fails on
-- open. nestly_v522 made the client agree; this makes the server agree. Shipping one without the
-- other is the disagreement, so they are one change.
--
-- NOT CHANGED, deliberately: 'staffperf' is gated on the CLIENT (FINANCE_MODULES) but is absent
-- from this server-side list, so a bookkeeper-shaped grant can still carry it here. That is a
-- pre-existing inconsistency of the same family, it predates this work, and widening the migration
-- to fix it would change the entitlement of a module nobody asked about. Recorded, not fixed.
--
-- NOT CHANGED, also deliberately: the platform flag economics_driver_policy_v109 stays OFF. Its
-- three RPCs refuse with 0A000 and not one of their numbers has ever been reconciled. nestly_v522
-- suppresses that section rather than rendering a placeholder, so enabling this module exposes only
-- surfaces whose figures are proven.
--
-- BODY. Otherwise byte-identical to the v246 definition — extracted with pg_get_functiondef from
-- production and diffed, so the only differences are the two described above.
--
-- ROLLBACK: db/tests/v523_customer_intelligence_follows_entitlement.sql

begin;

create or replace function app.staff_module_perms_at_v115(p_business uuid, p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* v246: body unchanged from v233 — only the language wrapper differs, so the
     plan is cached per connection instead of rebuilt on every call.
     v523: the unconditional customerintel='disabled' clause is gone, and the
     view_finance filter now covers customerintel alongside expenses and pnl. */
  return (
  with actor_staff as (
    select staff_row.*
    from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid()
      and staff_row.active
    order by case when staff_row.role='owner' then 0 else 1 end,
      staff_row.created_at,staff_row.id
    limit 1
  ),
  workspace as (
    select app.business_workspace_open_v94(p_business) as is_open
  ),
  module_keys as (
    select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
    from public.businesses business
    where business.id=p_business
    union
    select override_row.module_key
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
  ),
  branch_scopes as (
    select p_branch as branch_id,
      app.can_see_branch(p_business,p_branch) as visible
    where p_branch is not null
    union all
    select branch.id, app.can_see_branch(p_business,branch.id)
    from public.branches branch
    where p_branch is null
      and branch.business_id=p_business
      and branch.active
    union all
    select null::uuid, true
    where p_branch is null
      and not exists(
        select 1 from public.branches branch
        where branch.business_id=p_business
          and branch.active
      )
  ),
  scoped as (
    select module_keys.module_key, branch_scopes.branch_id, branch_scopes.visible,
      coalesce(
        (select override_row.mode
           from public.platform_module_overrides_v94 override_row
          where override_row.business_id=p_business
            and override_row.branch_scope=branch_scopes.branch_id
            and override_row.module_key=module_keys.module_key
            and override_row.mode<>'inherit'),
        (select override_row.mode
           from public.platform_module_overrides_v94 override_row
          where override_row.business_id=p_business
            and override_row.branch_scope is null
            and override_row.module_key=module_keys.module_key
            and override_row.mode<>'inherit'),
        (select case when module_keys.module_key=any(business.enabled_modules)
                  then 'rw' else 'disabled' end
           from public.businesses business
          where business.id=p_business)
      ) as platform_mode
    from module_keys
    cross join branch_scopes
  ),
  scoped_modes as (
    select scoped.module_key,
      case
        when not coalesce(workspace.is_open,false) then 'disabled'
        when scoped.branch_id is not null
             and not coalesce(scoped.visible,false) then 'disabled'
        when coalesce(scoped.platform_mode,'disabled')='disabled' then 'disabled'
        when actor_staff.role='owner' then scoped.platform_mode
        when staff_mode.mode='disabled' then 'disabled'
        when scoped.platform_mode='r' or staff_mode.mode='r' then 'r'
        else 'rw'
      end as access_mode,
      actor_staff.role
    from scoped
    cross join workspace
    cross join actor_staff
    cross join lateral (
      select case
        when actor_staff.module_perms is not null
          then coalesce(actor_staff.module_perms->>scoped.module_key,'disabled')
        when actor_staff.modules is null
          or scoped.module_key=any(actor_staff.modules) then 'rw'
        else 'disabled'
      end as mode
    ) staff_mode
  ),
  resolved as (
    select scoped_modes.module_key,
      case
        when bool_or(scoped_modes.access_mode='rw') then 'rw'
        when bool_or(scoped_modes.access_mode='r') then 'r'
        else 'disabled'
      end as access_mode,
      min(scoped_modes.role) as role
    from scoped_modes
    group by scoped_modes.module_key
  )
  select coalesce(
    jsonb_object_agg(resolved.module_key,resolved.access_mode)
      filter(where resolved.access_mode in ('r','rw')
        and (
          resolved.role='owner'
          or resolved.module_key not in ('branches','settings','setup')
        )
        and (
          resolved.module_key not in ('expenses','pnl','customerintel')
          or 'view_finance'=any(app.role_perms(resolved.role))
        )
      ),
    '{}'::jsonb
  )
  from resolved
  );
end
$function$;

/* Restated verbatim from the live proacl ({postgres=X/postgres}) — this function has never been
   callable by anon or authenticated. It is reached only through SECURITY DEFINER callers such as
   public.get_my_modules, so a grant here would widen the surface for no caller. */
revoke all on function app.staff_module_perms_at_v115(uuid, uuid) from public, anon, authenticated;

commit;
