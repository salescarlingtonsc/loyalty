-- Rollback-only acceptance for nestly_v521 — redemption off is a decision, and the two surfaces agree.
-- Run: supabase db query --linked -f db/tests/v521_redemption_off_is_a_decision.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- This suite carries plan item D — the standing guard. Assertions 05 and 06 run against LIVE
-- production data, not a fixture: they are the divergence probe that exposed the blind spot,
-- re-run as a check. Everything above them is the fixture proof that the new default behaves.
--
--   01  a capability row inserted WITHOUT naming redemption is now ON
--   02  ... while booking and appointment changes are still OFF by default
--   03  an explicit false is still honoured — the default never overrides a recorded decision
--   04  a business born today can mint a redemption QR end to end
--   05  THE GUARD: no live business disagrees with itself about whether a programme is running
--   06  THE GUARD: every live business has a capability row, so "missing" cannot mean "off"
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v521_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.as_v521_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust  uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_bare uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v521-acceptance-' || substr(gen_random_uuid()::text,1,8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_spine uuid; v_cfg uuid; v_reward uuid := gen_random_uuid();
  v_red boolean; v_book boolean; v_appt boolean;
  v_res jsonb; v_err text; v_n integer; v_names text;
begin
  -- ================= 01/02  THE NEW DEFAULT =================
  -- A business row is inserted, the v514 trigger seeds its capability row, and then that row is
  -- REPLACED by one that names only booking — the shape a future writer would produce if it
  -- forgot redemption exists. Before v521 that business's customers could not redeem anything.
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_bare,'V521 Bare','v521-bare-'||substr(v_bare::text,1,8),
          array['loyalty','clients'],'redeem');
  delete from public.business_customer_capabilities_v89 where business_id = v_bare;
  insert into public.business_customer_capabilities_v89(business_id, booking_enabled)
  values (v_bare, false);
  select redemption_enabled, booking_enabled, appointment_changes_enabled
    into v_red, v_book, v_appt
    from public.business_customer_capabilities_v89 where business_id = v_bare;
  insert into _r values('01_unspecified_redemption_is_on',
    case when v_red is true
      then 'PASS an insert that never mentions redemption leaves customers able to redeem'
      else 'FAIL redemption_enabled=' || coalesce(v_red::text,'null') end);
  insert into _r values('02_booking_and_appointments_still_default_off',
    case when v_book is false and v_appt is false
      then 'PASS the two surfaces that need configuring first were not switched on as a side effect'
      else 'FAIL booking=' || coalesce(v_book::text,'null')
           || ' appointments=' || coalesce(v_appt::text,'null') end);

  -- ================= 03  AN EXPLICIT FALSE IS A DECISION =================
  update public.business_customer_capabilities_v89
     set redemption_enabled = false where business_id = v_bare;
  select redemption_enabled into v_red
    from public.business_customer_capabilities_v89 where business_id = v_bare;
  insert into _r values('03_explicit_false_is_honoured',
    case when v_red is false
      then 'PASS a firm that has decided redemption is off keeps that decision — Bistro 999''s row is safe'
      else 'FAIL an explicit false was overridden' end);

  -- ================= 04  A BUSINESS BORN TODAY CAN MINT A QR =================
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_biz,'V521 Acceptance',v_slug,array['loyalty','clients','till','sales'],'redeem');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'zz-v521-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
          'zz-v521-c-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,active) values (v_biz,v_owner,'owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'V521 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v521', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v521_user(v_owner);
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,earn_points_per_dollar)
  values (v_biz,false,'classic','points','published',1);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points',true), gen_random_uuid());
  select id into v_spine from public.business_programmes where business_id=v_biz and kind='points';
  select active_config_version_id into v_cfg from public.businesses where id=v_biz;

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client,v_biz,'V521 Customer','+65 9521 1001');
  insert into public.customer_identities(id,auth_user_id,status) values (v_identity,v_cust,'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,
    programme_id,current_config_version_id)
  values (v_reward,v_biz,'V521 Gift','V521 Gift','V521 Gift','manual_item',1,0,0,true,false,1,v_spine,v_cfg);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,
    internal_name,customer_name,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,sort,programme_id)
  values (v_reward,v_biz,v_cfg,'V521 Gift','V521 Gift','manual_item',1,0,0,true,1,v_spine);
  perform public.adjust_points_v480(v_biz, v_client, 10, 'v521 fixture balance', gen_random_uuid());

  perform pg_temp.as_v521_user(v_cust);
  v_err := '';
  begin
    v_res := public.customer_create_redemption_intent_v89(
      p_business=>v_biz, p_reward=>v_reward,
      p_idempotency_key=>gen_random_uuid(), p_redemption_kind=>'catalog_reward');
  exception when others then get stacked diagnostics v_err = message_text;
  end;
  insert into _r values('04_new_business_can_mint_a_qr',
    case when v_res->>'status'='pending' and (v_res ? 'qr_token')
      then 'PASS a business created today produces a real token, with nobody having found a switch'
      else 'FAIL status=' || coalesce(v_res->>'status','none') || ' err=' || v_err end);
  perform set_config('request.jwt.claims','',true);

  -- ================= 05/06  THE STANDING GUARD, over LIVE data =================
  -- Deliberately not scoped to the fixture. This is the probe that found the blind spot; if any
  -- real business ever disagrees with itself again, this suite says which one.
  select count(*), string_agg(r.business_name, ', ')
    into v_n, v_names
    from app.customer_redemption_reachable_v521() r
   where not r.agrees and r.business_id not in (v_biz, v_bare);
  insert into _r values('05_no_live_business_disagrees_with_itself',
    case when v_n = 0
      then 'PASS every business reports the same programme state to its workspace and to its customers'
      else 'FAIL ' || v_n || ' diverged: ' || coalesce(v_names,'?') end);

  select count(*) into v_n from public.businesses b
   where not exists (select 1 from public.business_customer_capabilities_v89 c
                      where c.business_id = b.id);
  insert into _r values('06_every_business_has_a_capability_row',
    case when v_n = 0
      then 'PASS no business is one missing row away from silently refusing every customer QR'
      else 'FAIL ' || v_n || ' businesses have no capability row' end);
end $$;

select * from _r order by k;
rollback;
