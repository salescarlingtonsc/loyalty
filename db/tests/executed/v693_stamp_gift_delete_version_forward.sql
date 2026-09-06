-- Rollback-only nestly_v693 acceptance: deleting a stamp gift withdraws it from the NEXT card,
-- not from the one in the customer's hand (audit finding F038).
--
-- WHAT THE BUG WAS. public.business_delete_reward_v326 flipped public.loyalty_rewards.active on
-- the LIVE row and versioned nothing forward. Every stamp reader gates on that live row
-- (app.reward_availability_v432, app.redeem_reward_core, public.customer_get_stamp_card_v323,
-- public.customer_create_redemption_intent_v89, app.stamp_reward_expire_due_v464), so a customer
-- four stamps into a five-stamp card lost an already-earned gift the instant the owner pressed
-- Delete. Proven against production on 2026-09-02 in a rolled-back transaction: the gift went
-- from available_at_counter to ABSENT, redeem answered "reward not found or inactive", and the
-- customer's pinned config version — still carrying an active version row for that gift — was
-- never superseded, because no new version was ever published.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--   01  fixture: a customer with 4 of 5 stamps is pinned to version 1 and can claim the gift
--       sitting at stamp 3 (the positive control — without it every later assertion is vacuous)
--   02  the delete VERSIONS FORWARD: mode 'withdrawn', a NEW config version is published, and
--       the pinned version's own reward row is untouched (still active)
--   03  the new version withdraws the gift, and the live row records active=false + withdrawn_at
--   04  the pinned customer still SEES it: app.reward_availability_v432 still says
--       available_at_counter, and public.customer_get_stamp_card_v323 still lists the milestone
--   05  the pinned customer can still CLAIM it: app.redeem_reward_core succeeds and writes the
--       milestone claim (agreement between two readers is not correctness — this is the payout)
--   06  a customer whose card starts AFTER the withdrawal never sees it, while an untouched gift
--       on the same card is still offered (so 05 is about the pin, not about a broken filter)
--   07  no refusal is weakened: that new customer's redeem is refused
--   08  taking the LAST gift off the card PENDS with stamp_final_gift_missing and changes
--       nothing — the old code silently left a live stamp card publish_loyalty_config refuses
--   09  a POINTS gift still deletes outright: active=false, withdrawn_at NULL, no new version
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v693_stamp_gift_delete_version_forward.sql
-- Every check raises on failure, so the file either runs to its final notice or aborts.
--
-- TIME. now() is fixed for the whole transaction and app.stamp_cycle_version_v416 resolves the
-- pin by `published_at <= the customer's first stamp`. The fixture therefore backdates version 1
-- and the pinned customer's first stamp explicitly; the version this suite publishes lands at
-- now(), strictly after that stamp, which is exactly the ordering production has.

begin;

do $v693$
declare
  v_biz uuid := gen_random_uuid();
  v_cfg uuid;
  v_cfg2 uuid;
  v_spine uuid := gen_random_uuid();
  v_points_spine uuid;
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_client2 uuid := gen_random_uuid();
  v_free uuid := gen_random_uuid();
  v_big uuid := gen_random_uuid();
  v_pointgift uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid;
  v_seed uuid := gen_random_uuid();
  v_seed2 uuid := gen_random_uuid();
  v_res jsonb;
  v_txt text;
  v_uuid uuid;
  v_bool boolean;
  v_n integer;
  v_json jsonb;
begin
  -- ==========================================================================================
  -- FIXTURE — a stamps tenant, one customer 4 stamps into a 5-stamp card (recipe from
  -- db/tests/executed/v433_v436_stamp_lifecycle.sql phase 0).
  -- ==========================================================================================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'zz-v693-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
          'zz-v693-cust-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_biz,'V693 Stamp Kopi','zz-v693-'||substr(v_biz::text,1,8),array['loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  insert into public.business_programmes(id,business_id,kind,active,sort)
  values (v_spine,v_biz,'stamps',true,3)
  on conflict (business_id,kind) do update set active=true
  returning id into v_spine;
  update public.business_programmes set active=true where business_id=v_biz and kind='points';
  select id into v_points_spine from public.business_programmes
   where business_id=v_biz and kind='points';

  insert into public.staff(business_id,user_id,role,active,access_state)
  values (v_biz,v_owner,'owner',true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'V693 main',true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (v_biz,v_owner_staff,v_branch);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=v_owner,
         decided_at=clock_timestamp(),decision_reason='v693 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id) values (v_biz) on conflict do nothing;
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_wallet',true),('customer_claims',true),('customer_qr_redemption',true)
  on conflict (feature_key) do update set enabled=true;
  insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
  values (v_biz,true) on conflict (business_id) do update set redemption_enabled=true;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status,
                                      stamp_target,stamp_per_cents)
  values (v_biz,true,'stamps','stamps','published',5,500)
  on conflict (business_id) do update
    set active=true,loyalty_model='stamps',kind='stamps',configuration_status='published',
        stamp_target=5,stamp_per_cents=500;

  select id into v_cfg from public.firm_config_versions
   where business_id=v_biz and status='published' order by version_no desc limit 1;
  if v_cfg is null then
    raise exception 'FIXTURE BROKEN: the tenant has no published configuration version';
  end if;
  update public.businesses set active_config_version_id=v_cfg where id=v_biz;
  -- Version 1 was published two days ago; the pinned customer's first stamp is one day old. The
  -- version this suite publishes lands at now(), strictly after both.
  update public.firm_config_versions set published_at=now()-interval '2 days' where id=v_cfg;
  select stamp_target into v_n from public.loyalty_program_versions
   where config_version_id=v_cfg and business_id=v_biz;
  if v_n is distinct from 5 then
    raise exception 'FIXTURE BROKEN: version 1 carries stamp_target % (expected 5)', v_n;
  end if;

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client ,v_biz,'V693 Pinned Customer','+65 9693 0001'),
         (v_client2,v_biz,'V693 New Customer'   ,'+65 9693 0002');
  insert into public.customer_identities(id,auth_user_id,status)
  values (v_identity,v_cust,'active');
  declare v_link uuid := gen_random_uuid(); begin
    perform set_config('app.customer_link_insert_id',v_link::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                      verification_method,verified_at)
    values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
    perform set_config('app.customer_link_insert_id','',true);
  end;

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
  values
    (v_free     ,v_biz,'Free Coffee','Free Coffee','Free Coffee','manual_item',3,0,0,true,false,1,v_spine),
    (v_big      ,v_biz,'Big Gift'   ,'Big Gift'   ,'Big Gift'   ,'manual_item',5,0,0,true,false,2,v_spine),
    (v_pointgift,v_biz,'Points Mug' ,'Points Mug' ,'Points Mug' ,'manual_item',50,0,0,true,false,3,v_points_spine);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,description,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,sort,
    programme_id)
  values
    (v_free     ,v_biz,v_cfg,'Free Coffee','Free Coffee','Mid card','manual_item',3,0,0,1,v_spine),
    (v_big      ,v_biz,v_cfg,'Big Gift'   ,'Big Gift'   ,'Final'   ,'manual_item',5,0,0,2,v_spine),
    (v_pointgift,v_biz,v_cfg,'Points Mug' ,'Points Mug' ,'Points'  ,'manual_item',50,0,0,3,v_points_spine);

  -- The pinned customer: 4 stamps, collected a day ago. The EXCLUSIVE fence is taken rather than
  -- the shared one every till write uses: this suite is a single transaction, and
  -- app.acquire_loyalty_exclusive_v480 (which publish_loyalty_config takes when the delete
  -- publishes) refuses to upgrade a fence already held shared. Exclusive satisfies the ledger's
  -- app.require_loyalty_shared_v480 trigger too, so both halves of the suite are fenced correctly.
  perform app.acquire_loyalty_exclusive_v480(v_biz);
  perform set_config('app.points_ledger_insert_id',v_seed::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (v_seed,v_biz,v_client,'adjust',4,'v693 seed stamps',v_owner,v_spine,now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (v_biz,v_client,v_spine,4,4);

  -- ==========================================================================================
  -- 01  the positive control
  -- ==========================================================================================
  if app.stamp_cycle_version_v416(v_biz,v_client,v_spine) is distinct from v_cfg then
    raise exception '01 FAIL: the fixture customer is not pinned to version 1';
  end if;
  select ra.availability into v_txt
    from app.reward_availability_v432(v_biz,v_client) ra where ra.reward_id=v_free;
  if coalesce(v_txt,'ABSENT') is distinct from 'available_at_counter' then
    raise exception '01 FAIL: the fixture customer cannot claim the gift before the delete (%)',
      coalesce(v_txt,'ABSENT');
  end if;

  -- ==========================================================================================
  -- 02/03  the delete versions forward
  -- ==========================================================================================
  v_res := public.business_delete_reward_v326(v_biz,v_free);
  if coalesce(v_res->>'mode','') is distinct from 'withdrawn'
     or not coalesce((v_res->>'version_split')::boolean,false)
     or coalesce(v_res->>'publish_status','') is distinct from 'published' then
    raise exception '02 FAIL: deleting a stamp gift did not version forward and publish: %', v_res;
  end if;
  select active_config_version_id into v_cfg2 from public.businesses where id=v_biz;
  if v_cfg2 is null or v_cfg2 = v_cfg then
    raise exception '02 FAIL: no new configuration version was published (active is still %)', v_cfg2;
  end if;
  select rv.active into v_bool from public.loyalty_reward_versions rv
   where rv.reward_id=v_free and rv.config_version_id=v_cfg;
  if v_bool is distinct from true then
    raise exception '02 FAIL: the PINNED version''s reward row was rewritten (active=%) — the v416 pin was broken',
      v_bool;
  end if;
  select rv.active into v_bool from public.loyalty_reward_versions rv
   where rv.reward_id=v_free and rv.config_version_id=v_cfg2;
  if v_bool is distinct from false then
    raise exception '03 FAIL: the new version still carries the gift (active=%)', v_bool;
  end if;
  select 'active='||r.active||' withdrawn='||(r.withdrawn_at is not null)::text into v_txt
    from public.loyalty_rewards r where r.id=v_free;
  if v_txt is distinct from 'active=false withdrawn=true' then
    raise exception '03 FAIL: the live row reads % (expected active=false withdrawn=true)', v_txt;
  end if;

  -- ==========================================================================================
  -- 04  the pinned customer still sees it, on both readers
  -- ==========================================================================================
  if app.stamp_cycle_version_v416(v_biz,v_client,v_spine) is distinct from v_cfg then
    raise exception '04 FAIL: the publish moved the pinned customer onto the new version';
  end if;
  select ra.availability into v_txt
    from app.reward_availability_v432(v_biz,v_client) ra where ra.reward_id=v_free;
  if coalesce(v_txt,'ABSENT') is distinct from 'available_at_counter' then
    raise exception '04 FAIL: the withdrawn gift left the pinned customer''s counter list (%) — THE BUG',
      coalesce(v_txt,'ABSENT');
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_cust,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_json := public.customer_get_stamp_card_v323((select slug from public.businesses where id=v_biz));
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  if not exists (select 1 from jsonb_array_elements(v_json->'milestones') m
                  where m.value->>'reward_id' = v_free::text) then
    raise exception '04 FAIL: the withdrawn gift left the pinned customer''s own stamp card';
  end if;

  -- ==========================================================================================
  -- 05  and can actually claim it
  -- ==========================================================================================
  v_res := app.redeem_reward_core(v_biz,v_client,v_free,'v693-pinned-claim-01',v_branch)::jsonb;
  if not coalesce((v_res->>'ok')::boolean,false) then
    raise exception '05 FAIL: the pinned customer could not claim the withdrawn gift: %', v_res;
  end if;
  if not exists (select 1 from public.stamp_milestone_claims c
                  where c.business_id=v_biz and c.client_id=v_client and c.reward_id=v_free) then
    raise exception '05 FAIL: the claim did not reach stamp_milestone_claims';
  end if;

  -- ==========================================================================================
  -- 06/07  a customer whose card starts after the withdrawal never sees it, and is refused
  -- ==========================================================================================
  perform set_config('app.points_ledger_insert_id',v_seed2::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (v_seed2,v_biz,v_client2,'adjust',4,'v693 new card stamps',v_owner,v_spine,now());
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (v_biz,v_client2,v_spine,4,4);
  if app.stamp_cycle_version_v416(v_biz,v_client2,v_spine) is distinct from v_cfg2 then
    raise exception '06 FAIL: the new customer did not start on the new version';
  end if;
  select ra.availability into v_txt
    from app.reward_availability_v432(v_biz,v_client2) ra where ra.reward_id=v_free;
  if v_txt is not null then
    raise exception '06 FAIL: the new customer is still offered the withdrawn gift (%)', v_txt;
  end if;
  select ra.availability into v_txt
    from app.reward_availability_v432(v_biz,v_client2) ra where ra.reward_id=v_big;
  if coalesce(v_txt,'ABSENT') is distinct from 'insufficient_balance' then
    raise exception '06 FAIL: the untouched gift is not on the new customer''s card either (%) — the filter is too wide',
      coalesce(v_txt,'ABSENT');
  end if;
  begin
    perform app.redeem_reward_core(v_biz,v_client2,v_free,'v693-newcard-claim-01',v_branch);
    raise exception '07 FAIL: the new customer was allowed to claim a withdrawn gift';
  exception when others then
    if sqlerrm like '07 FAIL%' then raise; end if;
  end;

  -- ==========================================================================================
  -- 08  the last gift on the card cannot be taken off silently
  -- ==========================================================================================
  v_res := public.business_delete_reward_v326(v_biz,v_big);
  if coalesce(v_res->>'publish_status','') is distinct from 'pending'
     or not (v_res->'blockers')::text like '%stamp_final_gift_missing%' then
    raise exception '08 FAIL: removing the gift at the last stamp did not pend with blockers: %', v_res;
  end if;
  select r.active into v_bool from public.loyalty_rewards r where r.id=v_big;
  if v_bool is distinct from true then
    raise exception '08 FAIL: the pending delete switched the last gift off anyway (active=%)', v_bool;
  end if;
  if (select active_config_version_id from public.businesses where id=v_biz) is distinct from v_cfg2 then
    raise exception '08 FAIL: a pending delete published a version';
  end if;

  -- ==========================================================================================
  -- 09  a points gift still deletes outright
  -- ==========================================================================================
  v_res := public.business_delete_reward_v326(v_biz,v_pointgift);
  if coalesce(v_res->>'mode','') is distinct from 'deleted'
     or coalesce((v_res->>'version_split')::boolean,false) then
    raise exception '09 FAIL: a points gift no longer deletes outright: %', v_res;
  end if;
  select 'active='||r.active||' withdrawn='||(r.withdrawn_at is not null)::text into v_txt
    from public.loyalty_rewards r where r.id=v_pointgift;
  if v_txt is distinct from 'active=false withdrawn=false' then
    raise exception '09 FAIL: the points gift reads % (expected active=false withdrawn=false)', v_txt;
  end if;

  raise notice 'v693 ok: 9/9 — a deleted stamp gift is withdrawn from the next card only';
end
$v693$;

rollback;
