-- Rollback-only acceptance for nestly_v516 — a stamp gift the card calls READY can be shown as a QR.
-- Run: supabase db query --linked -f db/tests/v516_stamp_qr_asks_the_availability_core.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Owner (2026-08-25, photo 5, arrows at two "Show QR at counter" buttons): "why i press and
-- nothing come out". customer_create_redemption_intent_v89 compared the CURRENT card's filled
-- count to the reward cost, so every gift earned on a card the customer had already COMPLETED —
-- which v478/v496 deliberately made survive and stack — was refused "not enough stamps yet".
--
--   01  the fixture is the owner's screenshot: a customer whose card has rolled, holding gifts
--       earned on the completed card while the fresh card is nearly empty
--   02  the availability core says those gifts are claimable (it always did)
--   03  THE FIX: the intent now agrees — a QR is minted for a gift the card calls ready
--   04  a gift the customer has NOT earned is still refused (the gate still gates)
--   05  the points path is untouched
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v516_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.as_v516_user(uuid) to public;

create or replace function pg_temp.v516_ledger(
  p_biz uuid, p_client uuid, p_programme uuid, p_points integer, p_actor uuid)
returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_biz);
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger(id, business_id, client_id, programme_id,
                                   entry_type, points, reference, actor)
  values (v_id, p_biz, p_client, p_programme, 'adjust', p_points, 'v516 fixture', p_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
end $$;
grant execute on function pg_temp.v516_ledger(uuid,uuid,uuid,integer,uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v516-acceptance-' || substr(gen_random_uuid()::text,1,8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_spine uuid; v_cfg uuid;
  v_small uuid := gen_random_uuid();   -- 5 stamps  — earned on the completed card
  v_big   uuid := gen_random_uuid();   -- 12 stamps — never earned
  v_filled integer; v_avail text; v_res jsonb; v_err text;
begin
  -- ================= FIXTURE: the photo-5 shape =================
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_biz,'V516 Acceptance',v_slug,array['loyalty','clients','till','sales'],'redeem');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'zz-v516-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
          'zz-v516-c-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,active) values (v_biz,v_owner,'owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'V516 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v516', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v516_user(v_owner);
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,stamp_target,stamp_per_cents)
  values (v_biz,true,'stamps','stamps','published',10,500);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('stamps',true), gen_random_uuid());
  select id into v_spine from public.business_programmes where business_id=v_biz and kind='stamps';
  select active_config_version_id into v_cfg from public.businesses where id=v_biz;

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client,v_biz,'V516 Customer','+65 9516 1001');
  insert into public.customer_identities(id,auth_user_id,status) values (v_identity,v_cust,'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,
    programme_id,current_config_version_id)
  values (v_small,v_biz,'V516 Small','V516 Small','V516 Small','manual_item',5,0,0,true,false,1,v_spine,v_cfg),
         (v_big,  v_biz,'V516 Big','V516 Big','V516 Big','manual_item',12,0,0,true,false,2,v_spine,v_cfg);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,
    internal_name,customer_name,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,sort,programme_id)
  values (v_small,v_biz,v_cfg,'V516 Small','V516 Small','manual_item',5,0,0,true,1,v_spine),
         (v_big,  v_biz,v_cfg,'V516 Big','V516 Big','manual_item',12,0,0,true,2,v_spine);

  -- 11 stamps on a 10-slot card: the card completes and rolls, leaving 1 on the fresh card while
  -- the 5-stamp gift was genuinely EARNED on the card that closed. Exactly Devi M's shape.
  perform pg_temp.v516_ledger(v_biz, v_client, v_spine, 11, v_owner);
  perform app.stamp_complete_full_cycle_v489(v_biz, v_client, v_spine);

  select sp.filled into v_filled from app.stamp_progress_v323(v_biz,v_client) sp limit 1;
  insert into _r values('01_card_has_rolled',
    case when coalesce(v_filled,0) < 5
      then 'PASS the fresh card holds ' || coalesce(v_filled::text,'0') ||
           ' stamps — fewer than the 5-stamp gift costs, which is what broke the old gate'
      else 'FAIL filled=' || coalesce(v_filled::text,'null') end);

  select ra.availability into v_avail
    from app.reward_availability_v432(v_biz,v_client,now()) ra where ra.reward_id=v_small;
  insert into _r values('02_availability_says_ready',
    case when v_avail='available_at_counter'
      then 'PASS the availability core says the earned gift is claimable — it always did'
      else 'FAIL availability=' || coalesce(v_avail,'null') end);

  -- ================= 03  THE FIX =================
  perform pg_temp.as_v516_user(v_cust);
  v_err := '';
  begin
    v_res := public.customer_create_redemption_intent_v89(
      p_business=>v_biz, p_reward=>v_small,
      p_idempotency_key=>gen_random_uuid(), p_redemption_kind=>'catalog_reward');
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('03_qr_is_minted_for_a_ready_gift',
    case when v_res->>'status'='pending' and (v_res ? 'qr_token')
      then 'PASS pressing "Show QR at counter" now produces a token instead of "not enough stamps yet"'
      else 'FAIL ' || coalesce(nullif(v_err,''), 'status=' || coalesce(v_res->>'status','none')) end);

  -- ================= 04  THE GATE STILL GATES =================
  v_err := '';
  begin
    perform public.customer_create_redemption_intent_v89(
      p_business=>v_biz, p_reward=>v_big,
      p_idempotency_key=>gen_random_uuid(), p_redemption_kind=>'catalog_reward');
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('04_unearned_gift_still_refused',
    case when v_err like '%not enough stamps%'
      then 'PASS a gift the customer has not earned is still refused'
      else 'FAIL ' || coalesce(nullif(v_err,''),'the unearned gift was allowed') end);

  -- ================= 05  THE POINTS PATH IS UNTOUCHED =================
  insert into _r values('05_points_path_untouched',
    case when position('v_intent_programme_kind=''stamps''' in
           pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)) > 0
      then 'PASS the new gate lives inside the stamps branch only'
      else 'FAIL the stamps branch guard is gone' end);
end $$;

select * from _r order by k;
rollback;
