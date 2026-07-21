-- Run only against a rehearsal/production database after v21. Read-only
-- catalog assertions; wrapped in a rollback transaction for a uniform test API.
begin;

do $v21_test$
declare
  v_proc record;
  v_name text;
  v_expiry_proc oid;
  v_referral_proc oid;
  v_policy_helper_signatures text[];
  v_required_policy_helper_signatures constant text[] := array[
    'app.can_module(uuid,text)',
    'app.can_module_read(uuid,text)',
    'app.can_see_branch(uuid,uuid)',
    'app.has_perm(uuid,text)',
    'app.is_salon_member(uuid)',
    'app.is_salon_owner(uuid)',
    'app.is_super_admin()'
  ];
  v_authenticated_rpc_names constant text[] := array[
    'accept_invite', 'adjust_points', 'apply_module_template', 'close_drawer', 'commit_import_job',
    'convert_booking_request', 'create_business', 'create_client_field_definition', 'create_invite', 'create_loyalty_config_draft',
    'customer_claim_link_by_email', 'customer_claim_link_invitation', 'customer_create_identity',
    'customer_get_appointments', 'customer_get_appointments_page', 'customer_get_business_summary',
    'customer_get_identity', 'customer_get_loyalty_details', 'customer_get_memberships',
    'customer_get_packages', 'customer_get_reward_catalog', 'customer_get_wallet',
    'customer_get_birthday_benefit', 'customer_get_birthday_participation', 'customer_activate_birthday_benefit',
    'customer_get_notification_preferences', 'customer_issue_link_invitation', 'customer_portal_capabilities',
    'customer_request_appointment_action', 'customer_set_birthday_participation', 'customer_set_notification_preference', 'customer_unlink_business_link', 'decide_change',
    'enroll_membership', 'get_customer_feature_capabilities', 'get_dashboard_summary', 'get_my_access', 'get_my_modules', 'get_my_personas',
    'generate_retention_recommendation', 'get_active_birthday_program', 'get_birthday_program_draft', 'get_loyalty_reward_draft', 'get_retention_config_draft', 'get_notifications', 'get_reports_summary', 'get_revenue_summary', 'get_sale_policy',
    'import_bookings', 'issue_gift_card', 'lookup_client_by_phone',
    'mark_all_notifications_read', 'mark_notification_read', 'open_drawer',
    'record_credit_tender', 'record_drawer_movement',
    'record_payment', 'record_quick_sale', 'record_sale_by_phone',
    'reclassify_sale_policy', 'redeem_customer_birthday_benefit', 'redeem_gift_card', 'redeem_points', 'redeem_reward', 'redeem_reward_at_context', 'refund_sale',
    'reverse_customer_birthday_benefit_for_client', 'reverse_sale', 'reverse_loyalty_redemption', 'remove_loyalty_branch_override_draft',
    'save_birthday_program_draft', 'save_loyalty_branch_override_draft', 'save_loyalty_config_draft', 'save_retention_program_draft', 'save_reward_taxonomy', 'save_module_template', 'sell_package', 'set_booking_settings',
    'set_business_modules',
    'set_expense_void', 'set_sale_policy', 'set_staff_modules', 'stage_import_rows', 'publish_loyalty_config',
    'staff_get_reversal_workflows', 'super_admin_list_businesses', 'use_package_session'
  ];
  v_service_rpc_names constant text[] := array[
    'internal_gateway_rate_limit', 'internal_public_join_page', 'internal_public_join',
    'internal_public_booking_page', 'internal_public_booking_submit',
    'internal_public_booking_lookup', 'internal_public_booking_change'
  ];
begin
  v_expiry_proc := to_regprocedure('public.run_expiry_now(uuid)');
  if v_expiry_proc is null then
    raise exception 'missing retained public.run_expiry_now(uuid) contract';
  end if;

  v_referral_proc := to_regprocedure(
    'public.resolve_legacy_referral(uuid,uuid,uuid,text)');
  if v_referral_proc is null then
    raise exception 'missing retained public.resolve_legacy_referral(uuid,uuid,uuid,text) contract';
  end if;

  select coalesce(array_agg(distinct p.oid::regprocedure::text order by p.oid::regprocedure::text), array[]::text[])
    into v_policy_helper_signatures
    from pg_depend d
    join pg_policy pol
      on d.classid = 'pg_policy'::regclass and d.objid = pol.oid
    join pg_proc p
      on d.refclassid = 'pg_proc'::regclass and d.refobjid = p.oid
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app';

  if v_policy_helper_signatures is distinct from v_required_policy_helper_signatures then
    raise exception 'v17 policy helper dependency mismatch: expected %, found %',
      v_required_policy_helper_signatures, v_policy_helper_signatures;
  end if;

  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.prosecdef
       and (
         has_function_privilege('anon', p.oid, 'execute')
         or exists (
           select 1
             from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
            where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
         )
       )
  ) then
    raise exception 'SECURITY DEFINER function remains executable by anon/PUBLIC';
  end if;

  for v_proc in
    select distinct p.oid, p.oid::regprocedure as identity
      from pg_depend d
      join pg_policy pol
        on d.classid = 'pg_policy'::regclass and d.objid = pol.oid
      join pg_proc p
        on d.refclassid = 'pg_proc'::regclass and d.refobjid = p.oid
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
  loop
    if not has_function_privilege('authenticated', v_proc.oid, 'execute')
       or has_function_privilege('anon', v_proc.oid, 'execute') then
      raise exception 'required RLS helper % has an incorrect ACL', v_proc.identity;
    end if;
  end loop;

  if not has_function_privilege('authenticated', v_expiry_proc, 'execute')
     or has_function_privilege('anon', v_expiry_proc, 'execute')
     or exists (
       select 1
         from pg_proc p
         cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
        where p.oid = v_expiry_proc
          and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'public.run_expiry_now(uuid) has an incorrect ACL';
  end if;

  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'run_expiry_now'
       and p.oid <> v_expiry_proc
       and has_function_privilege('authenticated', p.oid, 'execute')
  ) then
    raise exception 'unexpected run_expiry_now overload is authenticated-executable';
  end if;

  if not has_function_privilege('authenticated', v_referral_proc, 'execute')
     or has_function_privilege('anon', v_referral_proc, 'execute')
     or exists (
       select 1
         from pg_proc p
         cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
        where p.oid = v_referral_proc
          and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'public.resolve_legacy_referral(uuid,uuid,uuid,text) has an incorrect ACL';
  end if;

  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'resolve_legacy_referral'
       and p.oid <> v_referral_proc
       and has_function_privilege('authenticated', p.oid, 'execute')
  ) then
    raise exception 'unexpected resolve_legacy_referral overload is authenticated-executable';
  end if;

  for v_name in select unnest(v_authenticated_rpc_names)
  loop
    -- Some historical names are optional across source-parity revisions. If a
    -- SECURITY DEFINER overload exists, it must retain authenticated-only EXECUTE.
    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name and p.prosecdef
    ) and not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name and p.prosecdef
         and has_function_privilege('authenticated', p.oid, 'execute')
         and not has_function_privilege('anon', p.oid, 'execute')
    ) then
      raise exception 'authenticated app RPC % has an incorrect ACL', v_name;
    end if;
  end loop;

  for v_name in select unnest(v_service_rpc_names)
  loop
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name and p.prosecdef
         and has_function_privilege('service_role', p.oid, 'execute')
         and not has_function_privilege('authenticated', p.oid, 'execute')
         and not has_function_privilege('anon', p.oid, 'execute')
    ) then
      raise exception 'service-only gateway RPC % has an incorrect ACL', v_name;
    end if;
  end loop;

  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public') and p.prosecdef
       and coalesce(array_to_string(p.proconfig, ','), '')
             not like '%search_path=pg_catalog, public, app, pg_temp%'
  ) then
    raise exception 'SECURITY DEFINER function has an unsafe or missing search_path';
  end if;

  if exists (
    select 1
      from pg_policy pol
      join pg_class rel on rel.oid = pol.polrelid
      join pg_namespace n on n.oid = rel.relnamespace
     where n.nspname = 'public'
       and pol.polcmd in ('a', 'w', '*')
       and regexp_replace(coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''), '[[:space:]()]', '', 'g') = 'true'
  ) then
    raise exception 'always-true public write policy remains';
  end if;

  if exists (
    select 1 from pg_policy pol join pg_class rel on rel.oid = pol.polrelid
      join pg_namespace n on n.oid = rel.relnamespace
     where n.nspname = 'public' and rel.relname = 'businesses'
       and pol.polname = 'salons_insert'
  ) or exists (
    select 1 from pg_policy pol join pg_class rel on rel.oid = pol.polrelid
      join pg_namespace n on n.oid = rel.relnamespace
     where n.nspname = 'public' and rel.relname = 'leads'
       and pol.polname = 'leads_insert_anon'
  ) then
    raise exception 'legacy unrestricted intake policy remains';
  end if;

  if has_table_privilege('anon', 'public.businesses', 'insert')
     or has_table_privilege('authenticated', 'public.businesses', 'insert')
     or has_table_privilege('anon', 'public.leads', 'insert')
     or has_table_privilege('anon', 'public.leads', 'update')
     or has_table_privilege('anon', 'public.leads', 'delete')
     or has_table_privilege('anon', 'public.leads', 'truncate')
     or has_table_privilege('authenticated', 'public.leads', 'insert')
     or has_table_privilege('authenticated', 'public.leads', 'update')
     or has_table_privilege('authenticated', 'public.leads', 'delete')
     or has_table_privilege('authenticated', 'public.leads', 'truncate') then
    raise exception 'direct unrestricted business or leads write privilege remains';
  end if;
end;
$v21_test$;

rollback;
