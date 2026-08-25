-- Rollback-only acceptance for nestly_v514 — "On" means live on BOTH sides.
-- Run: supabase db query --linked -f db/tests/v514_one_authority_for_on_means_live.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- THE DEFECT THIS PINS. The business surface gates on the v314 SPINE; the customer surface gates
-- on `coalesce(loyalty_programs.active,false) AND engine.running`, where engine.running is
-- literally `points_running or stamps_running`. set_programmes_v314 — the owner's On/Off switch —
-- never wrote `active`, so five live businesses read "On" in the workspace while their customers
-- saw no unit, no wordings and no catalogue. Separately, the redemption gate is
-- `coalesce(redemption_enabled,false)`, so a MISSING capability row silently disabled every
-- customer QR: it worked on Cubbly SPA and nowhere else.
--
--   01  switching points ON drives loyalty_programs.active true in the SAME call
--   02  switching everything OFF drives it back to false
--   03  a brand-new business is born with a customer-capability row, redemption ENABLED
--   04  THE STANDING GUARD: for a real customer, the customer reader and the business reader
--       report the SAME unit — the exact comparison that exposed the blind spot
--   05  the customer can actually mint a redemption QR (the gate that was silently false)
--   06  tiers alone do NOT set active — engine.running excludes tiers, so including it here
--       would re-create the divergence this migration removes
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v514_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v514_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust  uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v514-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_reward uuid := gen_random_uuid();
  v_spine uuid;
  v_cfg uuid;
  v_cust_json jsonb; v_biz_json jsonb; v_res jsonb;
  v_active boolean; v_n integer; v_txt text; v_err text;
begin
  -- ==========================================================================================
  -- FIXTURE — a business created the normal way, then switched on the normal way
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V514 Acceptance', v_slug,
          array['loyalty','clients','till','sales'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v514-owner-' || substr(v_owner::text,1,8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_cust, 'authenticated', 'authenticated',
          'zz-v514-cust-'  || substr(v_cust::text,1,8)  || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V514 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v514', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v514_user(v_owner);

  -- Seeded as onboarding seeds it: active=false. v507 births the config published.
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, earn_points_per_dollar)
  values (v_biz, false, 'classic', 'points', 'draft', 1);
  select b.active_config_version_id into v_cfg from public.businesses b where b.id=v_biz;

  -- ==========================================================================================
  -- 03  BORN WITH A CAPABILITY ROW, REDEMPTION ENABLED  (asserted early: it is a birth property)
  -- ==========================================================================================
  select redemption_enabled into v_active
    from public.business_customer_capabilities_v89 where business_id=v_biz;
  insert into _r values('03_born_redemption_enabled',
    case when v_active is true
      then 'PASS a new business can accept a customer redemption QR from birth'
      else 'FAIL redemption_enabled=' || coalesce(v_active::text,'NO ROW') end);

  -- ==========================================================================================
  -- 01  SWITCHING ON DRIVES loyalty_programs.active IN THE SAME CALL
  -- ==========================================================================================
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points', true), gen_random_uuid());
  select active into v_active from public.loyalty_programs where business_id=v_biz;
  insert into _r values('01_on_sets_active',
    case when v_active is true
      then 'PASS the owner''s On switch made loyalty_programs.active true in the same transaction'
      else 'FAIL loyalty_programs.active=' || coalesce(v_active::text,'null') end);

  -- ==========================================================================================
  -- 06  TIERS ALONE MUST NOT SET IT (engine.running excludes tiers)
  -- ==========================================================================================
  perform public.set_programmes_v314(v_biz,
    jsonb_build_object('points', false, 'tiers', true), gen_random_uuid());
  select active into v_active from public.loyalty_programs where business_id=v_biz;
  insert into _r values('06_tiers_alone_does_not_activate',
    case when v_active is false
      then 'PASS tiers alone leaves active false — it is excluded from engine.running too'
      else 'FAIL active=' || coalesce(v_active::text,'null') || ' with only tiers on' end);

  -- ==========================================================================================
  -- 02  EVERYTHING OFF DRIVES IT BACK
  -- ==========================================================================================
  perform public.set_programmes_v314(v_biz,
    jsonb_build_object('points', false, 'tiers', false, 'stamps', false), gen_random_uuid());
  select active into v_active from public.loyalty_programs where business_id=v_biz;
  insert into _r values('02_off_clears_active',
    case when v_active is false then 'PASS switching everything off clears active'
         else 'FAIL active=' || coalesce(v_active::text,'null') end);

  -- back on for the remaining assertions
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points', true), gen_random_uuid());

  -- ==========================================================================================
  -- 04  THE STANDING GUARD — the two surfaces must report the same unit
  -- ==========================================================================================
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V514 Customer', '+65 9514 1001');
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_biz, v_identity, v_cust, v_client, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('request.jwt.claims','',true);
  v_cust_json := app.c45_base_actionable_wallet_card(v_biz, v_client, v_slug, 'V514 Acceptance',
                   null, 'SGD', array['loyalty','clients','till','sales'], now());
  perform pg_temp.as_v514_user(v_owner);
  v_biz_json := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client, null);
  insert into _r values('04_surfaces_agree_on_unit',
    case when (v_cust_json#>>'{loyalty,unit}') is not distinct from (v_biz_json#>>'{program,unit}')
          and (v_cust_json#>>'{loyalty,unit}') = 'points'
      then 'PASS customer and business both report "points" — the blind spot is closed'
      else 'FAIL customer=' || coalesce(v_cust_json#>>'{loyalty,unit}','null')
           || ' business=' || coalesce(v_biz_json#>>'{program,unit}','null') end);

  -- ==========================================================================================
  -- 05  THE CUSTOMER CAN ACTUALLY MINT A QR
  -- ==========================================================================================
  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort,
    current_config_version_id)
  values (v_reward, v_biz, 'V514 Gift','V514 Gift','V514 Gift','manual_item', 1, 0, 0, true, false, 1, v_cfg);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, active, sort)
  values (v_reward, v_biz, v_cfg, 'V514 Gift','V514 Gift','manual_item', 1, 0, 0, true, 1);
  -- Through the sanctioned owner route, not a raw insert: public.points_ledger has a write guard
  -- that only approved loyalty routes may pass. This also exercises nestly_v512 — the correction
  -- must land in the RUNNING programme's pot, which is the points pot here.
  perform public.adjust_points_v480(v_biz, v_client, 10, 'v514 fixture balance', gen_random_uuid());

  perform pg_temp.as_v514_user(v_cust);
  v_err := '';
  begin
    v_res := public.customer_create_redemption_intent_v89(
      p_business=>v_biz, p_reward=>v_reward,
      p_idempotency_key=>gen_random_uuid(), p_redemption_kind=>'catalog_reward');
  exception when others then get stacked diagnostics v_err = message_text;
  end;
  insert into _r values('05_customer_can_mint_a_qr',
    case when v_res->>'status' = 'pending' and (v_res ? 'qr_token')
      then 'PASS "Show QR at counter" produces a real token on a brand-new business'
      else 'FAIL status=' || coalesce(v_res->>'status','none') || ' err=' || v_err end);
end $$;

select * from _r order by k;
rollback;
