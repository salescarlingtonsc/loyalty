-- Frenly v21: post-v20 least-privilege security hardening.
-- Canonical order: source parity through v17 -> v18 reporting -> v19 gateway
-- -> v20 financial engine -> v21 security hardening.
--
-- This migration is intentionally catalog-driven. PostgreSQL gives every new
-- function EXECUTE to PUBLIC by default, while the transferred schema contains
-- several historical SECURITY DEFINER functions. Revoke first, then restore
-- only the proven RLS, app-RPC, and service-only gateway call paths below.

begin;

-- The authenticated onboarding flow uses public.create_business(), which is a
-- SECURITY DEFINER RPC. Direct inserts can create an orphaned tenant without
-- the owner, default branch, loyalty, and audit rows that the RPC establishes.
drop policy if exists salons_insert on public.businesses;
revoke insert on table public.businesses from public, anon, authenticated;

-- The deployed product has no leads ingestion endpoint. Fail closed until a
-- separately reviewed, abuse-controlled backend intake path is introduced.
drop policy if exists leads_insert_anon on public.leads;
revoke insert, update, delete, truncate on table public.leads
  from public, anon, authenticated;

do $security_hardening$
declare
  v_proc record;
  v_policy_helper_signatures text[];
  v_required_policy_helper_signatures constant text[] := array[
    'app.can_module(uuid,text)',
    'app.can_see_branch(uuid,uuid)',
    'app.has_perm(uuid,text)',
    'app.is_salon_member(uuid)',
    'app.is_salon_owner(uuid)',
    'app.is_super_admin()'
  ];
  -- Derived from the shipped authenticated SPA RPC calls plus retained
  -- authenticated finance/admin RPCs. Names are resolved against pg_proc so
  -- this works with the transferred function signatures, not stale SQL files.
  v_authenticated_rpc_names constant text[] := array[
    'accept_invite',
    'adjust_points',
    'apply_module_template',
    'close_drawer',
    'convert_booking_request',
    'create_business',
    'create_invite',
    'decide_change',
    'enroll_membership',
    'get_dashboard_summary',
    'get_my_access',
    'get_my_modules',
    'get_notifications',
    'get_reports_summary',
    'get_revenue_summary',
    'get_sale_policy',
    'import_bookings',
    'issue_gift_card',
    'lookup_client_by_phone',
    'mark_all_notifications_read',
    'mark_notification_read',
    'open_drawer',
    'quick_add_client',
    'record_credit_tender',
    'record_drawer_movement',
    'record_payment',
    'record_quick_sale',
    'record_sale_by_phone',
    'reclassify_sale_policy',
    'redeem_gift_card',
    'redeem_points',
    'redeem_reward',  -- registry addition 2026-07-20 (v23/v24 catalog+stamps redemption); ACL applied by its own migrations
    'refund_sale',
    'reverse_sale',
    'save_module_template',
    'sell_package',
    'set_booking_settings',
    'set_expense_void',
    'set_sale_policy',
    'set_staff_modules',
    'super_admin_list_businesses',
    'use_package_session'
  ];
  v_service_rpc_names constant text[] := array[
    'internal_gateway_rate_limit',
    'internal_public_join_page',
    'internal_public_join',
    'internal_public_booking_page',
    'internal_public_booking_submit',
    'internal_public_booking_lookup',
    'internal_public_booking_change'
  ];
begin
  -- Derive the helpers directly referenced by active policies from PostgreSQL's
  -- dependency catalog. The exact v17 set is pinned so schema drift fails before
  -- any ACL changes instead of silently making a policy helper uncallable.
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
    raise exception 'v21 policy helper dependency mismatch: expected %, found %',
      v_required_policy_helper_signatures, v_policy_helper_signatures;
  end if;

  -- v18 also calls three members of this set through SECURITY INVOKER reports.
  -- Check exact identities, including the zero-argument super-admin predicate.
  if exists (
    select 1
    from unnest(v_required_policy_helper_signatures) required(signature)
    where to_regprocedure(required.signature) is null
  ) then
    raise exception 'v21 requires the transferred v17 helper signatures';
  end if;

  -- v3 exposed this exact manual, business-scoped expiry contract. Keep it as
  -- a signature exception rather than a name allowlist entry so no overload is
  -- accidentally restored by v21.
  if to_regprocedure('public.run_expiry_now(uuid)') is null then
    raise exception 'v21 requires public.run_expiry_now(uuid) from v20';
  end if;

  -- v20 retains this exact manual, business-scoped legacy referral resolution
  -- contract. Keep it signature-bound so no overload receives EXECUTE.
  if to_regprocedure('public.resolve_legacy_referral(uuid,uuid,uuid,text)') is null then
    raise exception 'v21 requires public.resolve_legacy_referral(uuid,uuid,uuid,text) from v20';
  end if;

  -- Trigger functions and non-public helpers do not need end-user EXECUTE.
  -- Every SECURITY DEFINER function gets a deterministic search path with
  -- pg_temp last, so temporary objects cannot shadow application objects.
  for v_proc in
    select n.nspname, p.proname, p.oid::regprocedure as identity
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.prosecdef
  loop
    execute format(
      'alter function %s set search_path to pg_catalog, public, app, pg_temp',
      v_proc.identity);
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_proc.identity);
  end loop;

  -- RLS predicates need authenticated EXECUTE. Restore the catalog-derived
  -- functions by exact identity; do not grant unrelated internal helpers.
  for v_proc in
    select distinct p.oid::regprocedure as identity
      from pg_depend d
      join pg_policy pol
        on d.classid = 'pg_policy'::regclass and d.objid = pol.oid
      join pg_proc p
        on d.refclassid = 'pg_proc'::regclass and d.refobjid = p.oid
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
  loop
    execute format('grant execute on function %s to authenticated', v_proc.identity);
  end loop;

  revoke all on function public.run_expiry_now(uuid)
    from public, anon, authenticated;
  grant execute on function public.run_expiry_now(uuid) to authenticated;

  revoke all on function public.resolve_legacy_referral(uuid, uuid, uuid, text)
    from public, anon, authenticated;
  grant execute on function public.resolve_legacy_referral(uuid, uuid, uuid, text)
    to authenticated;

  -- Restore only authenticated application RPCs. This preserves the current
  -- frontend and approved finance/admin operations without making historical
  -- phone-only/public RPCs callable again.
  for v_proc in
    select p.oid::regprocedure as identity
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (v_authenticated_rpc_names)
       and p.prosecdef
  loop
    execute format('grant execute on function %s to authenticated', v_proc.identity);
  end loop;

  -- v19 is exclusively invoked by Edge Functions using the service role.
  for v_proc in
    select p.oid::regprocedure as identity
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (v_service_rpc_names)
       and p.prosecdef
  loop
    execute format('grant execute on function %s to service_role', v_proc.identity);
  end loop;
end;
$security_hardening$;

commit;
