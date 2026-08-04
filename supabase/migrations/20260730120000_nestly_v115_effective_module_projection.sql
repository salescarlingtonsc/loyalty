-- NESTLY v115 — EFFECTIVE MODULE PROJECTION
--
-- Makes tenant persona/module discovery consume the same platform-effective
-- module modes already enforced by v94 write/read boundaries. This closes the
-- gap where a firm-level disable denied the action server-side but the owner
-- and staff navigation still advertised the raw sector entitlement.

begin;

create or replace function app.staff_module_perms_at_v115(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
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
  module_keys as (
    select unnest(business.enabled_modules) module_key
    from public.businesses business
    where business.id=p_business
    union
    select override_row.module_key
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
  ),
  resolved as (
    select module_keys.module_key,
      app.staff_module_mode_v94(
        p_business,p_branch,module_keys.module_key
      ) access_mode,
      actor_staff.role
    from module_keys
    cross join actor_staff
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
$$;

comment on function app.staff_module_perms_at_v115(uuid,uuid)
  is 'v115 current-actor module projection after platform firm/branch policy and staff-role permissions.';

revoke all on function app.staff_module_perms_at_v115(uuid,uuid)
  from public,anon,authenticated;

create or replace function app.staff_module_perms(p_business uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.staff_module_perms_at_v115(p_business,null)
$$;

revoke all on function app.staff_module_perms(uuid)
  from public,anon,authenticated;

create or replace function public.get_my_modules_at_v115(
  p_business uuid,
  p_branch uuid
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'modules',coalesce((
      select jsonb_agg(entry.key order by entry.key)
      from jsonb_each_text(
        app.staff_module_perms_at_v115(p_business,p_branch)
      ) entry
    ),'[]'::jsonb),
    'module_perms',app.staff_module_perms_at_v115(p_business,p_branch),
    'role',(
      select staff_row.role
      from public.staff staff_row
      where staff_row.business_id=p_business
        and staff_row.user_id=auth.uid()
        and staff_row.active
      order by case when staff_row.role='owner' then 0 else 1 end,
        staff_row.created_at,staff_row.id
      limit 1
    ),
    'is_super_admin',app.is_super_admin()
  )
$$;

comment on function public.get_my_modules_at_v115(uuid,uuid)
  is 'v115 authenticated branch-effective module projection for tenant controls; never broadens platform or staff policy.';

revoke all on function public.get_my_modules_at_v115(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.get_my_modules_at_v115(uuid,uuid)
  to authenticated;

commit;
