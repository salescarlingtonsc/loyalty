-- nestly_v569 -- a login is "active" only when the owner has actually approved it.
--
-- THE DEFECT (owner, 2026-08-28, photos 1+2): the roster showed teammate Siti as
-- "App access active" with 3 modules, while she met "Workspace unavailable · This workspace is
-- not available to this account" on every sign-in. She had signed up correctly and had signed in
-- 17:55 that day. Her staff row was active with a linked user_id -- and access_state='pending'.
--
-- THE STATE MACHINE HAD NO EXIT IN THE PRODUCT. public.accept_invite ALWAYS writes
-- access_state='pending' (deliberate: the owner confirms each login). public.decide_staff_access_v207
-- is the only writer that moves it to 'approved' -- and it had ZERO callers in app/app.js. So every
-- teammate who accepted an invite, in any tenant, was stranded permanently with no control anywhere
-- for the owner to release them. One row is in that state today; the next invite would join it.
--
-- FOUR READERS, ONE AUTHORITY, THREE OF THEM WRONG. The canonical rule is app.is_salon_member:
-- workspace open AND staff active AND access_state='approved'. Against it:
--   * app.is_salon_member (RLS on public.businesses)  - correct, and refused her
--   * public.get_my_personas   - reported workspace_access from the BUSINESS-level gate alone and
--                                routed her into the workspace she could not open
--   * app.billable_seats       - counted her as a billable seat (the owner was charged for a login
--                                that could not sign in)
--   * the roster UI            - printed "App access active" from `staff.user_id is not null`
--
-- THIS MIGRATION fixes the two server readers and exposes the state; nestly_v569's client half
-- gives the owner the Approve/Decline control that decide_staff_access_v207 always expected.
--
-- Deliberately NOT changed: accept_invite still writes 'pending'. Owner approval of each login is
-- the security posture, not the bug; the bug was that nothing surfaced or resolved it.
--
-- ROLLBACK: db/tests/v569_a_login_is_active_only_when_approved.sql

begin;

do $pre$
begin
  if position('and staff_row.access_state=''approved''' in pg_get_functiondef('public.get_my_personas()'::regprocedure)) > 0 then
    raise exception 'v569: get_my_personas already scopes workspace_access to the account';
  end if;
  if position('s.active and s.user_id is not null' in pg_get_functiondef('app.billable_seats(uuid)'::regprocedure)) = 0 then
    raise exception 'v569: expected the v14 seat definition to patch -- re-derive from the live definition';
  end if;
end
$pre$;

CREATE OR REPLACE FUNCTION public.get_my_personas()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
    /* nestly_v569: this said `app.business_workspace_open_v94(business.id)` — the BUSINESS-level
       gate. It answers "is this workspace open?" while every caller reads it as "can THIS account
       use it?", and those differ for a staff row whose login is still awaiting the owner's
       approval: public.accept_invite always writes access_state='pending', and RLS
       (app.is_salon_member) demands 'approved'. So a teammate who had accepted their invite was
       routed into a workspace every read then refused — the "Workspace unavailable" dead end the
       owner reported, while the roster called the same person "App access active".
       The account's own access_state now carries into the answer, and rides alongside it so the
       client can say WHICH of the two reasons applies instead of one blank refusal. */
    'workspace_access',app.business_workspace_open_v94(business.id)
      and staff_row.access_state='approved',
    'workspace_open',app.business_workspace_open_v94(business.id),
    'access_state',staff_row.access_state,
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
  /* nestly_v569: route to a workspace this account can actually OPEN. A staff persona awaiting
     approval is still returned (the client explains the wait), but it must not be the landing
     page — that is precisely how the teammate met a dead end on every sign-in. */
  if exists (select 1 from jsonb_array_elements(v_staff) persona
              where (persona->>'workspace_access')::boolean) then
    v_default_route:='#/workspace/'||(
      select persona->>'business_slug' from jsonb_array_elements(v_staff) persona
       where (persona->>'workspace_access')::boolean limit 1)||'/dashboard';
  elsif jsonb_array_length(v_staff)>0 and jsonb_array_length(v_customer)=0 then
    v_default_route:='#/';
  elsif jsonb_array_length(v_customer)>0 then
    v_default_route:='#/wallet';
  elsif v_identity then
    v_default_route:='#/claim';
  end if;
  return jsonb_build_object(
    'staff',v_staff,'customer',v_customer,'default_route',v_default_route
  );
end
$function$;

-- A seat is a login someone can actually USE. The v14 ruling ("a seat = staff.user_id IS NOT NULL
-- AND active") predates access_state; a row awaiting approval has a user_id and is active, and was
-- billed at +$10/mo while every read refused it. Charging for an unusable login is not a pricing
-- decision, it is an error -- so the seat now requires the same 'approved' the authority requires.
-- This can only ever LOWER a bill; nothing else about seat pricing changes.
CREATE OR REPLACE FUNCTION app.billable_seats(p_business uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  select count(*)::integer from public.staff s
  where s.business_id = p_business and s.active and s.user_id is not null
    and s.access_state = 'approved';
$function$;

-- ACLs restated verbatim from the live proacl of each function.
revoke all on function public.get_my_personas() from public, anon;
grant execute on function public.get_my_personas() to authenticated, service_role;
revoke all on function app.billable_seats(uuid) from public, anon, authenticated, service_role;

commit;
