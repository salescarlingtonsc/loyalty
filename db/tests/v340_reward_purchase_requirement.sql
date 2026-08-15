-- Rollback-only v340 acceptance: does claiming this reward require a purchase?
--
-- WHAT v340 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. requires_purchase exists on loyalty_rewards and loyalty_reward_versions, boolean not
--      null, defaulting to false — so every reward that already exists keeps meaning exactly
--      what it meant, and "false" is a statement of the engine's actual behaviour today.
--   2. save_loyalty_reward_draft accepts the key and stores it on the draft version.
--   3. Omitting the key leaves the stored value untouched (the same "unset means unchanged"
--      rule every other optional reward field already follows) — this is what keeps a client
--      built before the migration from silently clearing a flag it does not know about.
--   4. The allow-list did NOT open up: an unsupported key still raises 22023.
--   5. app.clone_reward_versions_for_config carries the flag into a new draft generation. This
--      is the failure mode V176 documented: an owner ticks the box, opens a new draft, and the
--      tick is silently gone.
--   6. publish_loyalty_config promotes the flag onto the live public.loyalty_rewards row.
--   7. get_loyalty_reward_draft returns it, so the owner editor reads back its own save instead
--      of resetting the control on every reopen.
--   8. customer_get_reward_catalog returns it for a verified customer — AND redemption is
--      completely unaffected in both directions. v340 adds a statement an owner makes about
--      their counter; it deliberately adds no enforcement, and app.redeem_reward_core is not
--      touched by the migration at all.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v340_reward_purchase_requirement.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v340_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v340_out to public;

create or replace function pg_temp.as_v340_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v340_system() to public;

create or replace function pg_temp.as_v340_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid::text,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v340_user(uuid,text) to public;

-- A minimal points-redeem tenant with one published, claimable reward and one verified
-- customer holding enough points to redeem it.
create or replace function pg_temp.v340_tenant(
  p_business uuid, p_owner uuid, p_client uuid, p_config uuid, p_reward uuid, p_label text,
  p_customer_auth uuid
) returns void language plpgsql as $$
declare
  v_link uuid := gen_random_uuid();
  v_identity uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v340-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_customer_auth,'authenticated','authenticated',
          'v340-customer-'||substr(p_customer_auth::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v340 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V340 Owner',true,'approved');
  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V340 Main',true,true);
  insert into public.clients(id,business_id,full_name)
  values (p_client,p_business,'V340 Client');

  insert into public.customer_identities(auth_user_id,status,created_via)
  values (p_customer_auth,'active','phone_registration')
  returning id into v_identity;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,p_business,v_identity,p_customer_auth,p_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at,snapshot_hash)
  values (p_config,p_business,1,'published',now(),md5('v340-'||p_business::text));
  update public.businesses set active_config_version_id=p_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    current_config_version_id)
  values (p_business,'points',true,'classic','published',100,500,'visits','none',null,1,p_config);
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,tier_basis,expiry_mode,expiry_days)
  values (p_business,p_config,'points','classic',true,1,100,500,'visits','none',null);

  update public.business_programmes set active=false where business_id=p_business;
  update public.business_programmes set active=true, activated_at=now()
   where business_id=p_business and kind='points';

  -- One live reward, and its version row under the published config.
  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,description,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,current_config_version_id)
  values (p_reward,p_business,'V340 Free Coffee','V340 Free Coffee','V340 Free Coffee',
          'A free coffee','manual_item',50,0,300,true,0,p_config);
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
  values (p_reward,p_business,p_config,'V340 Free Coffee','V340 Free Coffee','A free coffee',
          'manual_item',50,0,300,true,0);

  insert into public.points_ledger(business_id,client_id,points,entry_type,note)
  values (p_business,p_client,500,'earn','v340 fixture');
end
$$;
grant execute on function pg_temp.v340_tenant(uuid,uuid,uuid,uuid,uuid,text,uuid) to public;

do $v340_test$
declare
  bA uuid := gen_random_uuid(); oA uuid := gen_random_uuid(); cA uuid := gen_random_uuid();
  cAauth uuid := gen_random_uuid();
  cfgA uuid := gen_random_uuid(); rwA uuid := gen_random_uuid();
  v_draft1 uuid; v_draft2 uuid;
  v_result json; v_json jsonb; v_flag boolean; v_slug text; v_item jsonb;
begin
  perform pg_temp.as_v340_system();
  perform pg_temp.v340_tenant(bA, oA, cA, cfgA, rwA, 'V340 Alpha', cAauth);
  select slug into v_slug from public.businesses where id=bA;

  -- CELL 1: the column exists on both tables and defaults to false.
  select requires_purchase into v_flag from public.loyalty_rewards where id=rwA;
  if v_flag is false then
    insert into v340_out values (1,'requires_purchase defaults to false on an existing reward','PASS');
  else
    insert into v340_out values (1,'requires_purchase defaults to false on an existing reward',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;
  select requires_purchase into v_flag from public.loyalty_reward_versions
   where reward_id=rwA and config_version_id=cfgA;
  if v_flag is false then
    insert into v340_out values (2,'requires_purchase defaults to false on the version row','PASS');
  else
    insert into v340_out values (2,'requires_purchase defaults to false on the version row',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;

  -- CELL 3: the owner opens a draft and sets the flag through the real save path.
  perform pg_temp.as_v340_user(oA);
  select (public.create_loyalty_config_draft(bA, cfgA, 'owner_reward_editor')->>'version_id')::uuid
    into v_draft1;
  perform public.save_loyalty_config_draft(v_draft1, jsonb_build_object(
    'reward', jsonb_build_object('id', rwA, 'customer_name','V340 Free Coffee',
      'cost_points', 50, 'fulfillment_kind','manual_item', 'requires_purchase', true)), null);
  perform pg_temp.as_v340_system();
  select requires_purchase into v_flag from public.loyalty_reward_versions
   where reward_id=rwA and config_version_id=v_draft1;
  if v_flag is true then
    insert into v340_out values (3,'save_loyalty_reward_draft stores requires_purchase=true','PASS');
  else
    insert into v340_out values (3,'save_loyalty_reward_draft stores requires_purchase=true',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;

  -- CELL 4: omitting the key must leave the stored value alone, not reset it to the default.
  perform pg_temp.as_v340_user(oA);
  perform public.save_loyalty_config_draft(v_draft1, jsonb_build_object(
    'reward', jsonb_build_object('id', rwA, 'customer_name','V340 Free Coffee',
      'cost_points', 60, 'fulfillment_kind','manual_item')), null);
  perform pg_temp.as_v340_system();
  select requires_purchase into v_flag from public.loyalty_reward_versions
   where reward_id=rwA and config_version_id=v_draft1;
  if v_flag is true then
    insert into v340_out values (4,'an absent key leaves the stored requires_purchase untouched','PASS');
  else
    insert into v340_out values (4,'an absent key leaves the stored requires_purchase untouched',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;

  -- CELL 5: the allow-list is not now open to anything.
  perform pg_temp.as_v340_user(oA);
  begin
    perform public.save_loyalty_config_draft(v_draft1, jsonb_build_object(
      'reward', jsonb_build_object('id', rwA, 'customer_name','V340 Free Coffee',
        'cost_points', 60, 'fulfillment_kind','manual_item', 'not_a_real_field', true)), null);
    insert into v340_out values (5,'an unsupported reward key is still refused','FAIL - no exception raised');
  exception when others then
    insert into v340_out values (5,'an unsupported reward key is still refused','PASS');
  end;

  -- CELL 6: get_loyalty_reward_draft reads back what the editor saved.
  perform pg_temp.as_v340_user(oA);
  select public.get_loyalty_reward_draft(v_draft1) into v_json;
  perform pg_temp.as_v340_system();
  if exists (select 1 from jsonb_array_elements(coalesce(v_json->'rewards','[]'::jsonb)) r
              where (r->>'id')::uuid = rwA and (r->>'requires_purchase')::boolean is true) then
    insert into v340_out values (6,'get_loyalty_reward_draft returns requires_purchase','PASS');
  else
    insert into v340_out values (6,'get_loyalty_reward_draft returns requires_purchase',
      'FAIL - '||coalesce(v_json::text,'null'));
  end if;

  -- CELL 7: a NEW draft generation clones the flag rather than dropping it.
  perform pg_temp.as_v340_user(oA);
  select (public.create_loyalty_config_draft(bA, v_draft1, 'owner_reward_editor')->>'version_id')::uuid
    into v_draft2;
  perform pg_temp.as_v340_system();
  select requires_purchase into v_flag from public.loyalty_reward_versions
   where reward_id=rwA and config_version_id=v_draft2;
  if v_flag is true then
    insert into v340_out values (7,'clone_reward_versions_for_config carries requires_purchase','PASS');
  else
    insert into v340_out values (7,'clone_reward_versions_for_config carries requires_purchase',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;

  -- CELL 8: publish promotes it onto the live row.
  perform pg_temp.as_v340_user(oA);
  select public.publish_loyalty_config(v_draft2) into v_result;
  perform pg_temp.as_v340_system();
  select requires_purchase into v_flag from public.loyalty_rewards where id=rwA;
  if v_flag is true then
    insert into v340_out values (8,'publish_loyalty_config promotes requires_purchase','PASS');
  else
    insert into v340_out values (8,'publish_loyalty_config promotes requires_purchase',
      format('FAIL - got %s',coalesce(v_flag::text,'null')));
  end if;

  -- CELL 9: the customer catalogue reports it.
  perform pg_temp.as_v340_user(cAauth);
  select public.customer_get_reward_catalog(v_slug) into v_json;
  perform pg_temp.as_v340_system();
  select r into v_item from jsonb_array_elements(coalesce(v_json,'[]'::jsonb)) r
   where r->>'customer_name'='V340 Free Coffee' limit 1;
  if v_item is not null and (v_item->>'requires_purchase')::boolean is true then
    insert into v340_out values (9,'customer_get_reward_catalog returns requires_purchase','PASS');
  else
    insert into v340_out values (9,'customer_get_reward_catalog returns requires_purchase',
      'FAIL - '||coalesce(v_json::text,'null'));
  end if;

  -- CELL 10: clearing the flag flows the whole way back, so the customer surface can honestly
  -- print "No purchase required" only while the owner is actually saying it.
  perform pg_temp.as_v340_user(oA);
  select (public.create_loyalty_config_draft(bA, v_draft2, 'owner_reward_editor')->>'version_id')::uuid
    into v_draft1;
  perform public.save_loyalty_config_draft(v_draft1, jsonb_build_object(
    'reward', jsonb_build_object('id', rwA, 'customer_name','V340 Free Coffee',
      'cost_points', 60, 'fulfillment_kind','manual_item', 'requires_purchase', false)), null);
  perform public.publish_loyalty_config(v_draft1);
  perform pg_temp.as_v340_user(cAauth);
  select public.customer_get_reward_catalog(v_slug) into v_json;
  perform pg_temp.as_v340_system();
  select r into v_item from jsonb_array_elements(coalesce(v_json,'[]'::jsonb)) r
   where r->>'customer_name'='V340 Free Coffee' limit 1;
  if v_item is not null and (v_item->>'requires_purchase')::boolean is false then
    insert into v340_out values (10,'clearing requires_purchase reaches the customer catalogue','PASS');
  else
    insert into v340_out values (10,'clearing requires_purchase reaches the customer catalogue',
      'FAIL - '||coalesce(v_json::text,'null'));
  end if;

  -- CELL 11: v340 adds NO enforcement. The redemption kernel must be untouched — a reward
  -- marked requires_purchase=true is still redeemable on points alone, because the counter, not
  -- the software, is what the owner is describing. If this ever starts failing, someone has
  -- quietly turned a statement into a rule.
  perform pg_temp.as_v340_system();
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='app' and p.proname='redeem_reward_core' limit 1) not like '%requires_purchase%' then
    insert into v340_out values (11,'app.redeem_reward_core is not gated on requires_purchase','PASS');
  else
    insert into v340_out values (11,'app.redeem_reward_core is not gated on requires_purchase',
      'FAIL - the redemption kernel now reads a flag v340 never promised to enforce');
  end if;
end
$v340_test$;

select seq, step, outcome from v340_out order by seq;

rollback;
