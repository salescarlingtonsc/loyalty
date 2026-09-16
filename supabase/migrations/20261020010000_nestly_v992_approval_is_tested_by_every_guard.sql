-- nestly_v992 — approval is tested by every guard, not by two of them (2026-09-16).
--
-- THE DEFECT. nestly_v207 introduced public.staff.access_state and parked every invited teammate
-- at 'pending' until the owner approves them. Its own header states the premise that made it
-- wrong (db/migrations/20260807_nestly_v207_staff_invite_and_owner_approval.sql:20-21):
--
--     "The whole 'who is in this firm' boundary lives in app.is_salon_member /
--      app.is_salon_owner and nowhere else, which is why the gate is added to exactly
--      those two functions."
--
-- It does not live in those two. Measured against production before writing this file, SIX more
-- functions establish "the caller is staff of this business" from staff.user_id = auth.uid(), and
-- none of them tested access_state:
--
--     app.has_perm                              boolean gate, 78 policies reach it
--     app.can_see_branch                        boolean gate
--     app.staff_module_mode_v94                 engine behind app.can_module_read/_write
--     app.staff_module_perms_at_v115            the whole module map
--     public.platform_get_business_control_v94  own gate, no module check
--     public.get_my_modules_at_v115             reports the caller's role
--     public.owner_set_product_cost_v122        own owner test
--     public.owner_list_reward_profitability_products_v122   own owner test
--
-- WHAT THAT MEANT IN PRODUCTION. public.clients carries exactly two PERMISSIVE policies and no
-- RESTRICTIVE one; clients_v41_read is USING app.can_module_read(business_id,'clients'), which
-- resolves through staff_module_mode_v94. public.sales is USING app.has_perm(business_id,
-- 'view_sales') for SELECT and WITH CHECK app.has_perm(business_id,'create_sales') for INSERT.
-- So a teammate sitting at access_state='pending' — whose own screen says "Workspace
-- unavailable" and whose roster row says "Waiting for approval" — held a valid session that
-- could GET /rest/v1/clients?select=full_name,phone and read the shop's entire customer list with
-- mobile numbers, and POST /rest/v1/sales to write into the books. Reproduced against production
-- inside a rolled-back transaction: is_salon_member() returned false for that principal while the
-- table reads returned every row. Under Singapore PDPA the shop owner is the data controller and
-- a customer list leaving by this route is a notifiable breach.
--
-- The blast radius is wider than a rota-only invite. The legacy public.create_invite form is still
-- rendered (app/app.js:60503) and its accept_invite branch INSERTs a staff row with modules NULL
-- and module_perms NULL; staff_module_mode_v94's "v_staff.modules is null then rw" arm then reads
-- that as read-write on EVERY module the business has enabled.
--
-- WHY THE CLAUSE AND NOT A POLICY CHANGE. One authority per fact (CLAUDE.md). The eight functions
-- below are the only places that answer "is this caller staff here", so the clause goes in them
-- and all 78 policies inherit it with no policy edited. The wording is copied verbatim from what
-- v207 put into is_salon_member — `and <alias>.access_state='approved'` — so the estate now has
-- one spelling of the test rather than two.
--
-- SAFE FOR EVERY LIVE PRINCIPAL. Measured before writing: public.staff holds 34 rows and every one
-- is access_state='approved' AND active (0 pending, 0 rejected, 0 null). staff_access_state_ck
-- constrains the column to ('pending','approved','rejected') and the column carries no NULLs, so
-- `='approved'` cannot strand a legacy row. staff_salon_id_user_id_key is UNIQUE on
-- (business_id, user_id), so the `order by … limit 1` arms below select from at most one row
-- either way — for an approved caller the chosen row is unchanged, and for a pending caller the
-- arm now finds nothing and returns 'disabled' instead of a permission set.
--
-- record_sale_by_phone, use_package_session_v102 and the rest of the till are NOT edited here and
-- do not need to be: each gates on app.has_perm / app.can_module_read first and only then resolves
-- its own staff row for attribution, so they close transitively the moment the guards below do.
--
-- Bodies below are the live production text (pg_get_functiondef, read today), with the single
-- access_state clause added and nothing else touched.
--
-- Rollback suite: db/tests/v992_approval_is_tested_by_every_guard.sql

begin;

-- =============================================================================================
-- 0 · The live bodies are what this file believes they are, and the data is what it measured.
-- =============================================================================================
do $v992_assert$
declare
  v_body text;
  v_unapproved integer;
begin
  select count(*) into v_unapproved
    from public.staff
   where access_state is distinct from 'approved';
  if v_unapproved > 0 then
    raise exception 'v992: % staff row(s) are not approved — re-read the note before applying, '
      'because this migration will remove their access', v_unapproved;
  end if;

  foreach v_body in array array[
    'app.has_perm(uuid,text)',
    'app.can_see_branch(uuid,uuid)',
    'app.staff_module_mode_v94(uuid,uuid,text)',
    'app.staff_module_perms_at_v115(uuid,uuid)',
    'public.platform_get_business_control_v94(uuid)',
    'public.get_my_modules_at_v115(uuid,uuid)',
    'public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)',
    'public.owner_list_reward_profitability_products_v122(uuid)'
  ] loop
    if position('access_state' in pg_get_functiondef(v_body::regprocedure)) > 0 then
      raise exception 'v992: % already tests access_state — this migration has been applied '
        'or superseded', v_body;
    end if;
  end loop;

  -- The two functions v207 did fix must still carry the clause this file is copying.
  if position($needle$access_state='approved'$needle$ in
      pg_get_functiondef('app.is_salon_member(uuid)'::regprocedure)) = 0 then
    raise exception 'v992: app.is_salon_member no longer spells the approval test the way v207 '
      'left it — reconcile before copying it into eight more functions';
  end if;
end
$v992_assert$;

-- =============================================================================================
-- 1 · The two boolean gates. 78 of the 419 policies in public reach one of these.
-- =============================================================================================
create or replace function app.has_perm(p_business uuid, p_perm text)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.business_workspace_open_v94(p_business) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid() and staff_row.active
      and staff_row.access_state='approved'
      and p_perm=any(app.role_perms(staff_row.role))
  )
$function$;
/* Restated from the live proacl: {postgres=X/postgres,authenticated=X/postgres}. */
revoke all on function app.has_perm(uuid, text) from public, anon;
grant execute on function app.has_perm(uuid, text) to authenticated;

create or replace function app.can_see_branch(p_business uuid, p_branch uuid)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select case
    when auth.uid() is null then false
    when app.is_super_admin() then true
    when not app.business_workspace_open_v94(p_business) then false
    else exists(
      select 1 from public.staff staff_row
      where staff_row.business_id=p_business
        and staff_row.user_id=auth.uid() and staff_row.active
        and staff_row.access_state='approved'
        and (
          app.role_class(staff_row.role) in ('owner','admin')
          or (p_branch is not null and exists(
            select 1 from public.staff_branches assignment
            where assignment.business_id=p_business
              and assignment.staff_id=staff_row.id
              and assignment.branch_id=p_branch
          ))
        )
    )
  end
$function$;
/* Restated from the live proacl: {postgres=X/postgres,authenticated=X/postgres}. */
revoke all on function app.can_see_branch(uuid, uuid) from public, anon;
grant execute on function app.can_see_branch(uuid, uuid) to authenticated;

-- =============================================================================================
-- 2 · The module engine. app.can_module_read / can_module_write resolve through these, and so
--     does every clients / appointments / products / stock policy behind them.
-- =============================================================================================
create or replace function app.staff_module_mode_v94(p_business uuid, p_branch uuid, p_module text)
returns text
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_staff public.staff%rowtype;v_platform text;v_staff_mode text;
begin
  if not app.business_workspace_open_v94(p_business) then
    return 'disabled';
  end if;
  select * into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=auth.uid()
    and staff_row.active
    and staff_row.access_state='approved'
  order by case when staff_row.role='owner' then 0 else 1 end,
    staff_row.created_at,staff_row.id
  limit 1;
  if not found then return 'disabled';end if;
  if p_branch is not null
     and not app.can_see_branch(p_business,p_branch) then
    return 'disabled';
  end if;
  select resolved.mode into v_platform
  from app.effective_platform_module_mode_v94(
    p_business,p_branch,p_module
  ) resolved;
  if coalesce(v_platform,'disabled')='disabled' then return 'disabled';end if;
  if v_staff.role='owner' then
    return v_platform;
  elsif v_staff.module_perms is not null then
    v_staff_mode:=coalesce(v_staff.module_perms->>p_module,'disabled');
  elsif v_staff.modules is null or p_module=any(v_staff.modules) then
    v_staff_mode:='rw';
  else
    v_staff_mode:='disabled';
  end if;
  if v_staff_mode='disabled' then return 'disabled';end if;
  if v_platform='r' or v_staff_mode='r' then return 'r';end if;
  return 'rw';
end
$function$;
/* Restated from the live proacl: {postgres=X/postgres} — server-only, exactly as v94 left it. */
revoke all on function app.staff_module_mode_v94(uuid, uuid, text)
  from public, anon, authenticated;

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
     view_finance filter now covers customerintel alongside expenses and pnl.
     v992: actor_staff demands access_state='approved', so a teammate the owner
     has not approved resolves to an empty module map instead of their role's. */
  return (
  with actor_staff as (
    select staff_row.*
    from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid()
      and staff_row.active
      and staff_row.access_state='approved'
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
/* Restated from the live proacl: {postgres=X/postgres} — server-only, exactly as v115 left it. */
revoke all on function app.staff_module_perms_at_v115(uuid, uuid)
  from public, anon, authenticated;

-- =============================================================================================
-- 3 · The four callers that ask the question themselves instead of asking a guard.
--     get_my_modules_at_v115 reported a pending teammate's role; platform_get_business_control_v94
--     handed them the firm's approval and subscription state with no module test at all; the two
--     owner_*_v122 functions are closed transitively by can_module_write but are restated here so
--     the estate has one spelling of the test rather than two.
-- =============================================================================================
create or replace function public.get_my_modules_at_v115(p_business uuid, p_branch uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_perms jsonb;
begin
  v_perms := app.staff_module_perms_at_v115(p_business,p_branch);
  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'modules',coalesce((
      select jsonb_agg(entry.key order by entry.key)
      from jsonb_each_text(v_perms) entry
    ),'[]'::jsonb),
    'module_perms',v_perms,
    'role',(
      select staff_row.role
      from public.staff staff_row
      where staff_row.business_id=p_business
        and staff_row.user_id=auth.uid()
        and staff_row.active
        and staff_row.access_state='approved'
      order by case when staff_row.role='owner' then 0 else 1 end,
        staff_row.created_at,staff_row.id
      limit 1
    ),
    'is_super_admin',app.is_super_admin()
  );
end
$function$;
/* Restated from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.get_my_modules_at_v115(uuid, uuid) from public, anon;
grant execute on function public.get_my_modules_at_v115(uuid, uuid) to authenticated, service_role;

create or replace function public.platform_get_business_control_v94(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_result jsonb;
begin
  if not app.is_super_admin()
     and not app.platform_firm_report_access_v94(p_business)
     and not exists(
       select 1 from public.staff active_staff
       where active_staff.business_id=p_business
         and active_staff.user_id=auth.uid()
         and active_staff.active
         and active_staff.access_state='approved'
     ) then
    raise exception 'business_control_access_required' using errcode='42501';
  end if;
  select jsonb_build_object(
    'business_id',business.id,
    'approval',jsonb_build_object(
      'status',control.approval_status,'version',control.version,
      'decided_at',control.decided_at,'decided_by',control.decided_by,
      'reason',control.decision_reason
    ),
    'subscription',jsonb_build_object(
      'state',lifecycle.state,'due_date',lifecycle.due_date,
      'overdue_day',lifecycle.overdue_day,
      'workspace_paused',lifecycle.workspace_paused,
      'paused_at',lifecycle.paused_at,'recovered_at',lifecycle.recovered_at,
      'version',lifecycle.version
    ),
    'workspace_access',app.business_workspace_open_v94(business.id),
    'representative',case when representative.consultant_id is null then null
      else jsonb_build_object(
        'consultant_id',representative.consultant_id,
        'display_name',representative.display_name,
        'hotline_phone',representative.hotline_phone
      ) end,
    'catalogue_intelligence',jsonb_build_object(
      'enabled',setting.catalogue_intelligence_enabled,
      'version',setting.version,'updated_at',setting.updated_at
    ),
    'quick_earn_catalogue_enabled',
      checkout_setting.platform_allowed and checkout_setting.owner_enabled,
    'checkout_catalogue',jsonb_build_object(
      'platform_allowed',checkout_setting.platform_allowed,
      'owner_enabled',checkout_setting.owner_enabled,
      'enabled',
        checkout_setting.platform_allowed and checkout_setting.owner_enabled,
      'version',checkout_setting.version,
      'updated_at',checkout_setting.updated_at
    )
  ) into v_result
  from public.businesses business
  join public.business_workspace_controls_v94 control
    on control.business_id=business.id
  join public.business_subscription_lifecycle_v94 lifecycle
    on lifecycle.business_id=business.id
  join public.business_platform_intelligence_settings_v94 setting
    on setting.business_id=business.id
  join public.business_checkout_catalogue_settings_v94 checkout_setting
    on checkout_setting.business_id=business.id
  left join lateral app.assigned_consultant_v94(business.id) representative
    on true
  where business.id=p_business;
  if v_result is null then raise exception 'business_not_found' using errcode='22023';end if;
  return v_result;
end
$function$;
/* Restated from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.platform_get_business_control_v94(uuid) from public, anon;
grant execute on function public.platform_get_business_control_v94(uuid) to authenticated, service_role;

create or replace function public.owner_list_reward_profitability_products_v122(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null
     or not exists(
       select 1 from public.staff staff_row
       where staff_row.business_id=p_business
         and staff_row.user_id=auth.uid()
         and staff_row.active
         and staff_row.access_state='approved'
         and staff_row.role='owner'
     )
     or not app.can_module_write(p_business,'loyalty')
  then
    raise exception 'owner_loyalty_write_required' using errcode='42501';
  end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',product.id,'name',product.name,
      'retail_price_cents',product.retail_price_cents,
      'cost_cents',product.cost_cents
    ) order by product.name,product.id)
    from public.products product
    where product.business_id=p_business and product.active
  ),'[]'::jsonb));
end
$function$;
/* Restated from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.owner_list_reward_profitability_products_v122(uuid) from public, anon;
grant execute on function public.owner_list_reward_profitability_products_v122(uuid)
  to authenticated, service_role;

create or replace function public.owner_set_product_cost_v122(p_business uuid, p_product uuid, p_cost_cents bigint, p_expected_cost_cents bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_product public.products%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_product is null
     or p_cost_cents is null
     or p_cost_cents not between 0 and 2147483647
  then
    raise exception 'valid_product_cost_required' using errcode='22023';
  end if;
  if not exists(
       select 1 from public.staff staff_row
       where staff_row.business_id=p_business
         and staff_row.user_id=auth.uid()
         and staff_row.active
         and staff_row.access_state='approved'
         and staff_row.role='owner'
     )
     or not app.can_module_write(p_business,'loyalty')
  then
    raise exception 'owner_loyalty_write_required' using errcode='42501';
  end if;
  select * into v_product
  from public.products product
  where product.id=p_product and product.business_id=p_business and product.active
  for update;
  if not found then
    raise exception 'active_product_not_found' using errcode='P0002';
  end if;
  -- A replay after a lost response is harmless; a genuinely stale editor
  -- refuses instead of silently overwriting another owner.
  if v_product.cost_cents is not distinct from p_cost_cents then
    return jsonb_build_object(
      'id',v_product.id,'cost_cents',v_product.cost_cents,'replayed',true
    );
  end if;
  if v_product.cost_cents is distinct from p_expected_cost_cents then
    raise exception 'product_cost_changed_refresh_required' using errcode='40001';
  end if;
  update public.products
  set cost_cents=p_cost_cents
  where id=v_product.id
  returning * into v_product;
  return jsonb_build_object(
    'id',v_product.id,'cost_cents',v_product.cost_cents,'replayed',false
  );
end
$function$;
/* Restated from the live proacl: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.owner_set_product_cost_v122(uuid, uuid, bigint, bigint) from public, anon;
grant execute on function public.owner_set_product_cost_v122(uuid, uuid, bigint, bigint)
  to authenticated, service_role;

-- =============================================================================================
-- 4 · The post-condition: every function that answers "is this caller staff here" now tests
--     approval. This is the assertion that fails if a ninth one is ever added without it.
-- =============================================================================================
do $v992_post$
declare
  v_blind text[];
  /* public.record_sale_by_phone is the ONE accepted exemption, and it is an exemption on
     purpose rather than an oversight. Its first statement is
       if not app.has_perm(p_business,'create_sales')
          or not app.can_module_read(p_business,'clients') then raise 42501
     so authorization has already happened above; the staff lookup that matches the pattern
     below only resolves v_actor_staff for sale attribution, and it is unreachable by an
     unapproved caller now that has_perm tests approval. It is left untouched because
     restating a function of that size to add a clause that can never change its behaviour
     buys nothing and risks a transcription error in the till.

     If this assertion fails, a NINTH function has started establishing staff identity from
     auth.uid() without testing approval. Add the clause there; do not extend this list. */
begin
  select coalesce(array_agg(n.nspname||'.'||p.proname order by n.nspname, p.proname), '{}')
    into v_blind
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('app','public') and p.prokind='f'
     and pg_get_functiondef(p.oid) ~ 'staff[a-z_]*\.user_id\s*=\s*auth\.uid\(\)'
     and pg_get_functiondef(p.oid) !~ 'access_state';
  if v_blind <> array['public.record_sale_by_phone'] then
    raise exception 'v992: the set of functions establishing staff identity without an '
      'approval test is %, expected exactly {public.record_sale_by_phone}', v_blind;
  end if;
end
$v992_post$;

commit;
