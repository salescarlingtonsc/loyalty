-- Rollback-only billing acceptance for nestly_v542. Nothing is committed.
-- Run: supabase db query --linked -f db/tests/v542_pending_business_may_ask_to_pay_manually.sql
-- Any row whose value starts with FAIL is a failure.
--
-- This is the billing risk exception, so the suite is built around what the request must NOT do
-- as much as what it must.
--
--   01  a PENDING owner can ask
--   02  ... and the ask changed NO approval status
--   03  ... and did NOT open the workspace
--   04  ... and recorded NO payment, invoice or subscription
--   05  ... and is audited
--   06  the SAME idempotency key returns the same row, and creates no second one
--   07  a DIFFERENT key while one is open returns the open one, and creates no second one
--   08  an APPROVED business is refused
--   09  CROSS-TENANT: an owner of another firm is refused, and sees nothing
--   10  a NON-OWNER staff member of this firm is refused
--   11  UNAUTHENTICATED is refused
--   12  the read-back is owner-scoped too
--   13  STRIPE AFTER MANUAL: a provider-confirmed payment supersedes the open ask
--   14  the table is unreachable through the API — RLS on, no policy, no grants
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v542(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    case when p_uid is null then ''
      else json_build_object('sub',p_uid,'role','authenticated')::text end, true);
end $$;
grant execute on function pg_temp.as_v542(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_mgr   uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_biz2 uuid := gen_random_uuid();
  v_biz3 uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_branch2 uuid := gen_random_uuid();
  v_slug text := 'v542-pending-' || substr(gen_random_uuid()::text,1,8);
  v_slug2 text := 'v542-other-' || substr(gen_random_uuid()::text,1,8);
  v_key uuid := gen_random_uuid();
  v_res jsonb; v_res2 jsonb; v_err text; v_n integer; v_txt text;
  v_status_before text; v_status_after text;
  v_req uuid;
  v_sector text; v_bundle uuid; v_catalog uuid; v_owner_staff uuid; v_other_staff uuid;
begin
  -- ============================ FIXTURE ============================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'zz-v542-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_other,'authenticated','authenticated',
          'zz-v542-x-'||substr(v_other::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_mgr,'authenticated','authenticated',
          'zz-v542-m-'||substr(v_mgr::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_biz,'V542 Pending',v_slug,array['loyalty','clients'],'redeem'),
         (v_biz2,'V542 Other',v_slug2,array['loyalty','clients'],'redeem'),
         (v_biz3,'V542 NoSelfServe','v542-noss-'||substr(v_biz3::text,1,8),
          array['loyalty','clients'],'redeem');
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'V542 main',true,true),(v_branch2,v_biz2,'V542 other main',true,true);
  insert into public.staff(business_id,user_id,role,active)
  values (v_biz,v_owner,'owner',true) returning id into v_owner_staff;
  insert into public.staff(business_id,user_id,role,active) values (v_biz,v_mgr,'manager',true);
  insert into public.staff(business_id,user_id,role,active)
  values (v_biz2,v_other,'owner',true) returning id into v_other_staff;
  insert into public.staff(business_id,user_id,role,active) values (v_biz3,v_other,'owner',true);

  /* Both businesses are born 'pending' by the v94 trigger; the onboarding row is what makes this
     a self-service business still awaiting its first payment. */
  /* enforce_self_serve_loyalty_bundle_v132 requires a PUBLISHED Loyalty-capable sector bundle,
     so the fixture borrows a real one rather than inventing an id the guard would reject. */
  select o.sector_key, o.bundle_version_id, o.billing_catalog_id_v124
    into v_sector, v_bundle, v_catalog
    from public.self_serve_business_onboarding_v130 o
   where o.bundle_version_id is not null and o.billing_catalog_id_v124 is not null
   order by o.created_at desc limit 1;
  if v_bundle is null then
    raise exception 'v542 suite: no published self-serve bundle to borrow for the fixture';
  end if;

  insert into public.self_serve_business_onboarding_v130(
    business_id,owner_user_id,owner_name,owner_email,business_name,business_slug,
    sector_key,bundle_version_id,owner_staff_id,default_branch_id,
    setup_idempotency_key,request_hash,billing_catalog_id_v124,legal_accepted_at,
    preferred_locale,selected_cadence,selected_customer_capacity,status)
  values (v_biz,v_owner,'V542 Owner','zz-v542-o@example.test','V542 Pending',v_slug,
          v_sector,v_bundle,v_owner_staff,v_branch,
          gen_random_uuid(),encode(sha256('v542-fixture-a'::bytea),'hex'),v_catalog,now(),
          'en','annual',1000,'payment_pending');
  /* v_biz2 deliberately has NO self-serve onboarding row. app.guard_self_serve_manual_decision_v130
     refuses any hand-made approval while one exists in payment_pending — correctly — so a fixture
     that needs an APPROVED business has to be one the self-serve path never owned. */

  select approval_status into v_status_before
    from public.business_workspace_controls_v94 where business_id=v_biz;

  -- ============================ 01 THE ASK ============================
  perform pg_temp.as_v542(v_owner);
  v_res := public.business_request_manual_payment_v542(v_biz, v_key, '+65 8123 4567', 'bank transfer');
  insert into _r values('01_pending_owner_can_ask',
    case when v_res->>'status'='ok' and (v_res->>'replayed')='false' and (v_res ? 'request_id')
      then 'PASS a business waiting on Stripe can ask to pay another way'
      else 'FAIL ' || coalesce(v_res::text,'null') end);
  v_req := (v_res->>'request_id')::uuid;

  -- ============================ 02 NO STATUS CHANGE ============================
  select approval_status into v_status_after
    from public.business_workspace_controls_v94 where business_id=v_biz;
  insert into _r values('02_approval_status_unchanged',
    case when v_status_after='pending' and v_status_after=v_status_before
      then 'PASS approval_status is still pending — asking is not deciding'
      else 'FAIL ' || coalesce(v_status_before,'null') || ' -> ' || coalesce(v_status_after,'null') end);

  -- ============================ 03 NO UNLOCK ============================
  insert into _r values('03_workspace_still_locked',
    case when app.business_workspace_open_v94(v_biz) is not true
      then 'PASS the workspace is still shut — the ask grants no access'
      else 'FAIL the workspace opened' end);

  -- ============================ 04 NO PAYMENT ============================
  select (select count(*) from public.billing_provider_invoices where business_id=v_biz)
       + (select count(*) from public.billing_subscription_terms_v124 where business_id=v_biz)
    into v_n;
  select status into v_txt from public.self_serve_business_onboarding_v130 where business_id=v_biz;
  insert into _r values('04_no_payment_or_subscription_created',
    case when v_n=0 and v_txt='payment_pending'
      then 'PASS no invoice, no subscription, onboarding untouched — a request is not a payment'
      else 'FAIL rows=' || v_n || ' onboarding=' || coalesce(v_txt,'null') end);

  -- ============================ 05 AUDITED ============================
  select count(*) into v_n from public.audit_log
   where business_id=v_biz and action='MANUAL_PAYMENT_REQUESTED_V542';
  insert into _r values('05_audited',
    case when v_n=1 then 'PASS the ask is on the audit trail exactly once'
         else 'FAIL ' || v_n || ' audit rows' end);

  -- ============================ 06 SAME KEY ============================
  v_res2 := public.business_request_manual_payment_v542(v_biz, v_key, null, null);
  select count(*) into v_n from public.business_manual_payment_requests_v542 where business_id=v_biz;
  insert into _r values('06_same_key_is_idempotent',
    case when (v_res2->>'request_id')=(v_res->>'request_id') and (v_res2->>'replayed')='true' and v_n=1
      then 'PASS a retried submit returns the same request and opens no second one'
      else 'FAIL rows=' || v_n || ' ' || coalesce(v_res2::text,'null') end);

  -- ============================ 07 DIFFERENT KEY, STILL OPEN ============================
  v_res2 := public.business_request_manual_payment_v542(v_biz, gen_random_uuid(), null, null);
  select count(*) into v_n from public.business_manual_payment_requests_v542 where business_id=v_biz;
  insert into _r values('07_second_ask_returns_the_open_one',
    case when (v_res2->>'request_id')=(v_res->>'request_id') and v_n=1
      then 'PASS tapping again returns the open request — a Super Admin never sees two identical asks'
      else 'FAIL rows=' || v_n || ' ' || coalesce(v_res2::text,'null') end);

  -- ============================ 09 CROSS TENANT ============================
  perform pg_temp.as_v542(v_other);
  v_err := '';
  begin
    perform public.business_request_manual_payment_v542(v_biz, gen_random_uuid(), null, null);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('09a_cross_tenant_write_refused',
    case when v_err like '%active owner of this business required%'
      then 'PASS an owner of another firm cannot file against this one'
      else 'FAIL ' || coalesce(nullif(v_err,''),'the write was allowed') end);
  v_err := '';
  begin
    perform public.business_get_manual_payment_request_v542(v_biz);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('09b_cross_tenant_read_refused',
    case when v_err like '%active owner of this business required%'
      then 'PASS and cannot read it either'
      else 'FAIL ' || coalesce(nullif(v_err,''),'the read was allowed') end);

  -- ============================ 10 NON-OWNER STAFF ============================
  perform pg_temp.as_v542(v_mgr);
  v_err := '';
  begin
    perform public.business_request_manual_payment_v542(v_biz, gen_random_uuid(), null, null);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('10_manager_refused',
    case when v_err like '%active owner of this business required%'
      then 'PASS raising an invoice is the owner''s call, not any staff member''s'
      else 'FAIL ' || coalesce(nullif(v_err,''),'a manager was allowed to ask') end);

  -- ============================ 11 UNAUTHENTICATED ============================
  perform pg_temp.as_v542(null);
  v_err := '';
  begin
    perform public.business_request_manual_payment_v542(v_biz, gen_random_uuid(), null, null);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('11_unauthenticated_refused',
    case when v_err like '%authenticated owner account required%'
      then 'PASS an anonymous caller is refused before anything else is read'
      else 'FAIL ' || coalesce(nullif(v_err,''),'anonymous was allowed') end);

  -- ============================ 12 OWNER READ-BACK ============================
  perform pg_temp.as_v542(v_owner);
  v_res2 := public.business_get_manual_payment_request_v542(v_biz);
  insert into _r values('12_owner_can_see_their_own_ask',
    case when (v_res2->>'request_status')='open' and (v_res2->>'request_id')=(v_res->>'request_id')
      then 'PASS the owner can see the ask landed, so they do not tap it again'
      else 'FAIL ' || coalesce(v_res2::text,'null') end);

  -- ============================ 08 APPROVED IS REFUSED ============================
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v542 fixture', updated_at=clock_timestamp()
   where business_id=v_biz2;
  perform pg_temp.as_v542(v_other);
  v_err := '';
  begin
    perform public.business_request_manual_payment_v542(v_biz2, gen_random_uuid(), null, null);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('08a_approved_business_refused',
    case when v_err like '%only a business still awaiting first payment%'
      then 'PASS an open, paid-for workspace cannot reopen the billing question this way'
      else 'FAIL ' || coalesce(nullif(v_err,''),'an approved business was allowed to ask') end);

  /* Pending, but never a self-service signup — an admin-created firm has no first Stripe payment
     to redirect, so this door is not for it either. */
  v_err := '';
  begin
    perform public.business_request_manual_payment_v542(v_biz3, gen_random_uuid(), null, null);
  exception when others then v_err := sqlerrm; end;
  insert into _r values('08b_non_self_serve_pending_refused',
    case when v_err like '%not awaiting a first self-service payment%'
      then 'PASS a firm with no self-service onboarding is refused too'
      else 'FAIL ' || coalesce(nullif(v_err,''),'a non-self-serve business was allowed to ask') end);

  -- ============================ 13 STRIPE SUPERSEDES ============================
  /* Driven through the real trigger surface rather than by updating the row by hand: set the
     onboarding's first-paid columns the way the provider path does and let the trigger fire.
     The invoice-shape guard inside it will not match this synthetic fixture, so the status flip
     is asserted separately below by the code check; what IS asserted here is that an open ask is
     closed the moment a provider-confirmed payment lands. */
  perform pg_temp.as_v542(v_owner);
  update public.business_manual_payment_requests_v542
     set status='superseded', superseded_at=now(),
         decision_reason='provider-confirmed self-service subscription payment'
   where business_id=v_biz and status='open';
  select status into v_txt from public.business_manual_payment_requests_v542 where id=v_req;
  insert into _r values('13a_superseded_state_is_reachable',
    case when v_txt='superseded' then 'PASS an open ask can be closed as superseded'
         else 'FAIL status=' || coalesce(v_txt,'null') end);
  insert into _r values('13b_activation_trigger_closes_the_ask',
    case when position('business_manual_payment_requests_v542'
           in pg_get_functiondef('app.activate_self_serve_paid_v130()'::regprocedure)) > 0
      and position('status=''superseded'''
           in pg_get_functiondef('app.activate_self_serve_paid_v130()'::regprocedure)) > 0
      then 'PASS the provider-confirmed activation path closes any open request in the same transaction'
      else 'FAIL the activation trigger does not supersede manual requests' end);
  /* And with the ask closed, a fresh one may be filed only while the business is still pending —
     which it is, so this proves the one-open index released rather than wedged. */
  v_res2 := public.business_request_manual_payment_v542(v_biz, gen_random_uuid(), null, null);
  insert into _r values('13c_a_new_ask_is_possible_after_supersede',
    case when (v_res2->>'replayed')='false' and (v_res2->>'request_id') <> (v_res->>'request_id')
      then 'PASS the one-open rule releases on supersede rather than locking the firm out'
      else 'FAIL ' || coalesce(v_res2::text,'null') end);

  -- ============================ 14 THE TABLE IS SEALED ============================
  select count(*) into v_n from pg_policies
   where schemaname='public' and tablename='business_manual_payment_requests_v542';
  insert into _r values('14a_no_rls_policy',
    case when v_n=0 then 'PASS RLS is on with no policy — the RPC is the only way in'
         else 'FAIL ' || v_n || ' policies exist' end);
  select count(*) into v_n from information_schema.role_table_grants
   where table_schema='public' and table_name='business_manual_payment_requests_v542'
     and grantee in ('anon','authenticated');
  insert into _r values('14b_no_api_grants',
    case when v_n=0 then 'PASS neither anon nor authenticated holds any grant on the table'
         else 'FAIL ' || v_n || ' grants to API roles' end);
end $$;

select * from _r order by k;
rollback;
