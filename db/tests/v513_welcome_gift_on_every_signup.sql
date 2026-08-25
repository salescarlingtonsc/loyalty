-- Rollback-only acceptance for nestly_v513 — a new customer gets the welcome gift however they
-- were signed up.
-- Run: supabase db query --linked -f db/tests/v513_welcome_gift_on_every_signup.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Before v513, app.issue_welcome_offer_v215 had exactly two callers — internal_public_join_v89
-- and customer_join_business_from_qr_v89_base_v90 — both CUSTOMER SELF-SIGNUP. Every staff-side
-- and portal-side route created a customer with no grant, so Hougang ABC had 8 customers and a
-- no-minimum "Candy Floss" that none of them ever received.
--
--   01  staff_create_client (Customers form / onboarding) now grants
--   02  quick_add_client (till fast path) now grants — and the 'existing' branch does NOT re-grant
--   03  app.upsert_portal_client (public booking portal) now grants
--   04  the grant is what the TILL reads: staff_get_customer_entitlements_v102 returns it
--   05  a paused welcome offer grants nothing (the issuer's own gate still rules)
--   06  a customer who has already bought gets nothing (the issuer's own gate still rules)
--   07  idempotent: creating the same customer twice never yields two grants
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v513_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v513_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v513-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_service uuid := gen_random_uuid();
  v_staff uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid;
  v_json jsonb; v_n integer; v_txt text;
begin
  -- ==========================================================================================
  -- FIXTURE — a business with an ACTIVE welcome offer, no minimum spend
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V513 Acceptance', v_slug,
          array['loyalty','clients','till','sales','appointments','bookings'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v513-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  select id into v_staff from public.staff where business_id=v_biz and user_id=v_owner;
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V513 main', true, true);
  insert into public.services(id, business_id, name, duration_min, price_cents, active)
  values (v_service, v_biz, 'V513 Facial', 60, 8800, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v513', updated_at=clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v513_user(v_owner);

  -- catalog_shape_check: kind 'custom' requires reward_catalog_id NULL and custom_label set.
  insert into public.business_welcome_offers_v215(
    business_id, active, reward_label, reward_catalog_kind, reward_catalog_id,
    custom_label, min_spend_cents, expiry_days)
  values (v_biz, true, 'Free Candy Floss', 'custom', null, 'Free Candy Floss', 0, 30);

  -- ==========================================================================================
  -- 01  staff_create_client — the largest hole before v513
  -- ==========================================================================================
  v_json := public.staff_create_client(v_biz, gen_random_uuid(), 'V513 Staff Created',
              '+65 9513 0001', null, null, null, false, null, null);
  v_c1 := (v_json ->> 'client_id')::uuid;
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c1 and status='granted';
  insert into _r values('01_staff_create_client_grants',
    case when v_n = 1 then 'PASS a customer added by staff now receives the welcome gift'
         else 'FAIL ' || v_n || ' grants for a staff-created customer' end);

  -- ==========================================================================================
  -- 02  quick_add_client — and its 'existing' branch must NOT re-grant
  -- ==========================================================================================
  v_json := public.quick_add_client(v_biz, '+65 9513 0002', 'V513 Quick Add', false)::jsonb;
  v_c2 := (v_json ->> 'client_id')::uuid;
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c2 and status='granted';
  insert into _r values('02_quick_add_grants',
    case when v_json ->> 'status' = 'created' and v_n = 1
      then 'PASS the till fast path grants on a genuinely new customer'
      else 'FAIL status=' || coalesce(v_json ->> 'status','null') || ' grants=' || v_n end);
  -- same phone again: the 'existing' branch returns early and must not issue a second gift
  v_json := public.quick_add_client(v_biz, '+65 9513 0002', 'V513 Quick Add', false)::jsonb;
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c2;
  insert into _r values('02_existing_branch_does_not_regrant',
    case when v_json ->> 'status' = 'existing' and v_n = 1
      then 'PASS re-adding an existing customer issues nothing further'
      else 'FAIL status=' || coalesce(v_json ->> 'status','null') || ' grants=' || v_n end);

  -- ==========================================================================================
  -- 03  the public booking portal
  -- ==========================================================================================
  v_c3 := app.upsert_portal_client(v_biz, 'V513 Portal', '+65 9513 0003', null);
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c3 and status='granted';
  insert into _r values('03_portal_grants',
    case when v_n = 1 then 'PASS booking through the public portal grants the welcome gift'
         else 'FAIL ' || v_n || ' grants for a portal-created customer' end);

  -- ==========================================================================================
  -- 04  THE TILL SEES IT — this is the owner's actual complaint
  -- ==========================================================================================
  v_json := public.staff_get_customer_entitlements_v102(v_biz, v_c1);
  v_txt := v_json #>> '{welcome_offer,reward_label}';
  insert into _r values('04_till_reads_the_gift',
    case when v_txt = 'Free Candy Floss'
      then 'PASS Record sale now reports the welcome gift for a staff-created customer'
      else 'FAIL till welcome_offer=' || coalesce(v_json #>> '{welcome_offer}', 'ABSENT') end);

  -- ==========================================================================================
  -- 05  A PAUSED OFFER GRANTS NOTHING (the issuer's own gate, unchanged)
  -- ==========================================================================================
  update public.business_welcome_offers_v215 set active=false where business_id=v_biz;
  v_json := public.staff_create_client(v_biz, gen_random_uuid(), 'V513 While Paused',
              '+65 9513 0004', null, null, null, false, null, null);
  v_c4 := (v_json ->> 'client_id')::uuid;
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c4;
  insert into _r values('05_paused_offer_grants_nothing',
    case when v_n = 0 then 'PASS a switched-off welcome offer still issues nothing'
         else 'FAIL ' || v_n || ' grants while the offer is paused' end);
  update public.business_welcome_offers_v215 set active=true where business_id=v_biz;

  -- ==========================================================================================
  -- 06  A CUSTOMER WHO HAS ALREADY BOUGHT GETS NOTHING
  -- ==========================================================================================
  v_c5 := gen_random_uuid();
  insert into public.clients(id, business_id, full_name, phone)
  values (v_c5, v_biz, 'V513 Already Bought', '+65 9513 0005');
  insert into public.sales(business_id, client_id, staff_id, branch_id, kind, amount_cents, note)
  values (v_biz, v_c5, v_staff, v_branch, 'quick_sale', 4200, 'v513 prior purchase');
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c5;
  perform app.issue_welcome_offer_v215(v_biz, v_c5);
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c5;
  insert into _r values('06_prior_purchase_blocks',
    case when v_n = 0 then 'PASS a customer who has already bought is not a new sign-up'
         else 'FAIL ' || v_n || ' grants for a customer with a prior sale' end);

  -- ==========================================================================================
  -- 07  IDEMPOTENT
  -- ==========================================================================================
  perform app.issue_welcome_offer_v215(v_biz, v_c1);
  perform app.issue_welcome_offer_v215(v_biz, v_c1);
  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id=v_biz and client_id=v_c1;
  insert into _r values('07_idempotent',
    case when v_n = 1 then 'PASS repeated issuance never yields a second gift'
         else 'FAIL ' || v_n || ' grants after three issue calls' end);
end $$;

select * from _r order by k;
rollback;
