-- ============================================================================
-- v246 — get_my_personas stops paying the resolver-wrapper tax.
--
-- WHY. get_my_personas (the most-called authenticated RPC after notifications:
-- ~1,400 calls in the stats window, on every navigation and persona screen)
-- resolved each workspace's module list through TWO nested `language sql`
-- SECURITY DEFINER wrappers: app.staff_modules -> app.staff_module_perms ->
-- app.staff_module_perms_at_v115. A `language sql` function body is REPLANNED
-- on every call (5-14ms planning on this instance, measured), and each wrapper
-- hop adds its own. Measured composition: the v233 resolver itself is ~4ms
-- warm; the wrapper chain turns that into ~29ms per staff row, and
-- get_my_personas into ~51ms.
--
-- THE FIX — the exact v233 pattern, applied one level up:
--   1. get_my_personas calls app.staff_module_perms_at_v115(business, null)
--      DIRECTLY and extracts the sorted key list inline — the same expression
--      app.staff_modules evaluates, without the two wrapper plans. The three
--      platform_feature_enabled('customer_*') probes are hoisted into locals
--      evaluated once (the same flags were previously probed up to four times).
--   2. app.staff_module_perms_at_v115 becomes `language plpgsql` with its
--      SELECT preserved verbatim inside `return (...)`. plpgsql caches the
--      statement plan per connection, so on PostgREST's pooled connections the
--      5-14ms replanning is paid once per pool worker, not once per request.
--      This is the same deliberate sql->plpgsql inlining/plan change v233 made
--      to get_my_modules, now on the resolver itself; volatility, SECURITY
--      DEFINER, search_path, arguments and body semantics are unchanged.
--
-- WHAT DOES NOT CHANGE. The get_my_personas payload is byte-compatible:
-- staff[] (with `modules` — still consumed by the browser as the fail-closed
-- fallback when get_my_modules errors), customer[], default_route, the same
-- ordering, the same 28000 guard, the same workspace/lifecycle/consultant
-- joins. app.staff_modules and app.staff_module_perms keep existing unchanged
-- for their other callers.
--
-- IDEMPOTENT: create or replace only; safe to re-run.
-- ============================================================================

begin;

create or replace function app.staff_module_perms_at_v115(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  /* v246: body unchanged from v233 — only the language wrapper differs, so the
     plan is cached per connection instead of rebuilt on every call. */
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
      case when module_keys.module_key='customerintel' then 'disabled'
      else coalesce(
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
      ) end as platform_mode
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
          resolved.module_key not in ('expenses','pnl')
          or 'view_finance'=any(app.role_perms(resolved.role))
        )
      ),
    '{}'::jsonb
  )
  from resolved
  );
end
$$;

comment on function app.staff_module_perms_at_v115(uuid,uuid) is
  'v233 set-based module resolver; v246 wraps the identical SELECT in plpgsql '
  'so the plan is cached per connection instead of being rebuilt on every call '
  '(language sql bodies replan each invocation, 5-14ms on this instance). '
  'Decision rules unchanged since the v233 differential verification.';

create or replace function public.get_my_personas()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_staff jsonb:='[]'::jsonb;
  v_customer jsonb:='[]'::jsonb;
  v_default_route text:='#/';
  /* v246: each flag was probed up to four times per call; once is enough. */
  v_identity boolean:=app.platform_feature_enabled('customer_identity');
  v_claims boolean:=app.platform_feature_enabled('customer_claims');
  v_wallet boolean:=app.platform_feature_enabled('customer_wallet');
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode='28000';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id',business.id,
    'business_slug',business.slug,
    'business_name',business.name,
    'role',staff_row.role,
    /* v246: the sorted key list of the resolver's map — the exact expression
       app.staff_modules computes — read from a DIRECT resolver call instead of
       through two language-sql wrapper hops that each replan per invocation. */
    'modules',(
      select coalesce(array_agg(key.k order by key.k),array[]::text[])
      from jsonb_object_keys(
        app.staff_module_perms_at_v115(staff_row.business_id,null)
      ) as key(k)
    ),
    'workspace_access',app.business_workspace_open_v94(business.id),
    'approval_status',control.approval_status,
    'subscription_state',lifecycle.state,
    'workspace_paused',lifecycle.workspace_paused,
    'representative_name',representative.display_name,
    'representative_hotline',representative.hotline_phone
  ) order by business.name,business.slug),'[]'::jsonb)
  into v_staff
  from public.staff staff_row
  join public.businesses business on business.id=staff_row.business_id
  join public.business_workspace_controls_v94 control
    on control.business_id=business.id
  join public.business_subscription_lifecycle_v94 lifecycle
    on lifecycle.business_id=business.id
  left join lateral app.assigned_consultant_v94(business.id) representative
    on true
  where staff_row.user_id=v_actor and staff_row.active;
  if v_identity and v_claims and v_wallet then
    select coalesce(jsonb_agg(jsonb_build_object(
      'business_slug',business.slug,
      'business_name',business.name
    ) order by business.name,business.slug),'[]'::jsonb)
    into v_customer
    from public.customer_identities identity_row
    join public.customer_links link
      on link.identity_id=identity_row.id
      and link.auth_user_id=v_actor and link.state='verified'
    join public.businesses business on business.id=link.business_id
    where identity_row.auth_user_id=v_actor
      and identity_row.status='active';
  end if;
  if jsonb_array_length(v_staff)>0 then
    v_default_route:='#/workspace/'||(v_staff->0->>'business_slug')||'/dashboard';
  elsif jsonb_array_length(v_customer)>0 then
    v_default_route:='#/wallet';
  elsif v_identity then
    v_default_route:='#/claim';
  end if;
  return jsonb_build_object(
    'staff',v_staff,'customer',v_customer,'default_route',v_default_route
  );
end
$$;

comment on function public.get_my_personas() is
  'v246: identical payload (staff incl. modules fallback list, customer, '
  'default_route), but the module list comes from a direct '
  'staff_module_perms_at_v115 call instead of the staff_modules -> '
  'staff_module_perms wrapper chain, and the customer feature flags are probed '
  'once. Measured on production data: 48.3ms -> 21.2ms mean (15.6ms best), '
  'the residual being one genuine resolver evaluation per workspace.';

/* On the live database create-or-replace preserves the existing ACL, but on a
   fresh replay the default PUBLIC execute grant would apply — restate the v21
   posture explicitly for the exact overload. */
revoke all on function public.get_my_personas() from public, anon;
grant execute on function public.get_my_personas() to authenticated;
grant execute on function public.get_my_personas() to service_role;
revoke all on function app.staff_module_perms_at_v115(uuid,uuid) from public, anon;

commit;

-- ============================================================================
-- VERIFICATION BEFORE APPLY (rolled back against production):
--   * differential: old vs new get_my_personas byte-equal (jsonb) for every
--     real auth user (staff, customer-only, both, none), plus synthetic
--     multi-workspace, suspended-workspace, staff modules/module_perms
--     variants, and all eight customer feature-flag combinations;
--   * resolver: old (sql) vs new (plpgsql) staff_module_perms_at_v115
--     byte-equal across the same actor/branch matrix as v233;
--   * headers: prosecdef / volatility / search_path / acl unchanged;
--     28000 guard intact for anon.
-- ============================================================================
