-- Rollback-only v300 growth readbacks contract.
-- Proves the three read-only projections against synthetic tenants:
--   1. customer_get_referral_card_v300 returns the member's own code and the firm's CURRENT
--      terms; a programme that is off (either the row or the module) yields {"enabled":false}
--      with no code and no terms; an unlinked authenticated outsider gets 42501; anon cannot
--      execute at all.
--   2. staff_list_returned_customers_v300 counts exactly the customers whose latest valid
--      visit closed a gap of >= away_days inside the window, using the SAME valid-visit
--      predicate as retention_lapsed_candidates_v244 (reversed visits cannot "return").
--   3. business_reward_redemption_counts_v300 counts real loyalty_redemptions rows per
--      reward, reports classic (reward-less) redemptions separately, and refuses non-staff.

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v300_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v300_user(uuid,text) to public;

do $v300_test$
declare
  v_owner uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_business uuid;
  v_slug text;
  v_identity uuid;
  v_link uuid := gen_random_uuid();
  v_client uuid;
  v_friend_a uuid; v_friend_b uuid; v_friend_c uuid;
  v_a uuid := gen_random_uuid();  -- away 85d, back 5d ago -> returned
  v_b uuid := gen_random_uuid();  -- away 50d, last visit 40d ago -> outside window
  v_c uuid := gen_random_uuid();  -- single visit -> new, not returned
  v_d uuid := gen_random_uuid();  -- away 62d, back 3d ago -> returned (newest)
  v_e uuid := gen_random_uuid();  -- comeback visit reversed away -> not returned
  v_e_orig uuid;
  v_r1 uuid := gen_random_uuid(); v_r2 uuid := gen_random_uuid();
  v_branch uuid;
  v_card jsonb; v_res jsonb; v_counts jsonb;
begin
  reset role;
  insert into public.businesses(name,slug,industry,currency,enabled_modules)
  values(
    'V300 growth readbacks',
    'v300-growth-' || substr(gen_random_uuid()::text,1,8),
    'test','SGD',
    array['dashboard','clients','sales','loyalty','retention','referrals']
  ) returning id,slug into v_business,v_slug;
  perform set_config('app.v79_system_transition', '', true);

  -- app.business_workspace_open_v94 gates the customer-effective module set; a raw
  -- fixture business needs the approved control + unpaused lifecycle rows that
  -- create_business writes for real tenants.
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v300-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
     'v300-customer-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v300-outsider-'||substr(v_outsider::text,1,8)||'@example.test','',now(),now(),now());

  -- The businesses trigger auto-creates a pending control + lifecycle pair; the fixture
  -- only flips the decision to approved the way platform review would.
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(),
         decision_reason='v300 rollback fixture'
   where business_id=v_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_business)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id=v_business;

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key = 'customer_wallet';

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V300 Owner',true);

  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration') returning id into v_identity;
  insert into public.clients(business_id,full_name,phone,referral_code)
  values(v_business,'V300 Referrer','+6580003000','V300AB') returning id into v_client;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.clients(business_id,full_name,phone) values
    (v_business,'V300 Friend A','+6580013000') returning id into v_friend_a;
  insert into public.clients(business_id,full_name,phone) values
    (v_business,'V300 Friend B','+6580023000') returning id into v_friend_b;
  insert into public.clients(business_id,full_name,phone) values
    (v_business,'V300 Friend C','+6580033000') returning id into v_friend_c;

  insert into public.referral_programs(business_id,enabled,reward_cents,min_spend_cents)
  values(v_business,true,800,2000);
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status) values
    (v_business,v_client,v_friend_a,'pending'),
    (v_business,v_client,v_friend_b,'qualified'),
    (v_business,v_client,v_friend_c,'rewarded');

  -- ---- 1. referral card ----
  perform pg_temp.as_v300_user(v_customer);
  v_card := public.customer_get_referral_card_v300(v_slug);
  if v_card->>'enabled' is distinct from 'true'
     or v_card->>'code' is distinct from 'V300AB'
     or (v_card->>'reward_cents')::integer is distinct from 800
     or (v_card->>'min_spend_cents')::integer is distinct from 2000
     or v_card->>'currency' is distinct from 'SGD'
     or (v_card->>'referred_count')::integer is distinct from 2 then
    raise exception 'referral card did not project the firm''s live terms: %', v_card;
  end if;
  reset role;

  update public.referral_programs set enabled=false where business_id=v_business;
  perform pg_temp.as_v300_user(v_customer);
  v_card := public.customer_get_referral_card_v300(v_slug);
  if v_card is distinct from jsonb_build_object('enabled',false) then
    raise exception 'a disabled programme must return only {"enabled":false}: %', v_card;
  end if;
  reset role;
  update public.referral_programs set enabled=true where business_id=v_business;

  update public.businesses
     set enabled_modules = array_remove(enabled_modules,'referrals')
   where id = v_business;
  perform pg_temp.as_v300_user(v_customer);
  v_card := public.customer_get_referral_card_v300(v_slug);
  if v_card is distinct from jsonb_build_object('enabled',false) then
    raise exception 'a switched-off referrals module must hide the card: %', v_card;
  end if;
  reset role;
  update public.businesses
     set enabled_modules = enabled_modules || array['referrals']
   where id = v_business;

  perform pg_temp.as_v300_user(v_outsider);
  begin
    perform public.customer_get_referral_card_v300(v_slug);
    raise exception 'authenticated outsider read a referral card';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v300_user(null,'anon');
  begin
    perform public.customer_get_referral_card_v300(v_slug);
    raise exception 'anon executed customer_get_referral_card_v300';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- ---- 2. returned customers ----
  insert into public.clients(id,business_id,full_name,phone) values
    (v_a,v_business,'V300 Back After 85','+6580043000'),
    (v_b,v_business,'V300 Still Away','+6580053000'),
    (v_c,v_business,'V300 First Timer','+6580063000'),
    (v_d,v_business,'V300 Back After 62','+6580073000'),
    (v_e,v_business,'V300 Reversed Return','+6580083000');
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note) values
    (v_business,v_a,'quick_sale',1000,now()-interval '90 days','v300'),
    (v_business,v_a,'quick_sale',1000,now()-interval '5 days','v300'),
    (v_business,v_b,'quick_sale',1000,now()-interval '90 days','v300'),
    (v_business,v_b,'quick_sale',1000,now()-interval '40 days','v300'),
    (v_business,v_c,'quick_sale',1000,now()-interval '5 days','v300'),
    (v_business,v_d,'quick_sale',1000,now()-interval '70 days','v300'),
    (v_business,v_d,'quick_sale',1000,now()-interval '65 days','v300'),
    (v_business,v_d,'quick_sale',1000,now()-interval '3 days','v300'),
    (v_business,v_e,'quick_sale',1000,now()-interval '100 days','v300');
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,note)
    values (v_business,v_e,'quick_sale',1000,now()-interval '4 days','v300')
    returning id into v_e_orig;
  -- The comeback that never happened: reverse E's recent visit (same trigger-off idiom as
  -- the v244 suite; the whole transaction rolls back).
  alter table public.sales disable trigger user;
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at,
      counts_as_visit,counts_as_revenue,earns_points,policy_resolved_at,
      commission_rate_bps,commission_resolved_at,reversal_of,
      reversal_reason,reversal_actor,reversal_idempotency_key,note)
  values (v_business,v_e,'quick_sale',-1000,now()-interval '3 days',true,false,false,now(),
      0,now(),v_e_orig,'v300 fixture reversal',v_owner,'v300-rev-'||v_e_orig,'v300 reversal');
  alter table public.sales enable trigger user;

  perform pg_temp.as_v300_user(v_owner);
  v_res := public.staff_list_returned_customers_v300(v_business,60,30);
  if (v_res->>'total_returned')::integer is distinct from 2 then
    raise exception 'expected exactly A and D to have returned: %', v_res;
  end if;
  if v_res#>>'{rows,0,id}' is distinct from v_d::text
     or (v_res#>>'{rows,0,away_days}')::integer is distinct from 62
     or v_res#>>'{rows,1,id}' is distinct from v_a::text
     or (v_res#>>'{rows,1,away_days}')::integer is distinct from 85 then
    raise exception 'returned rows must be newest-first with exact away gaps: %', v_res;
  end if;
  v_res := public.staff_list_returned_customers_v300(v_business,60,4);
  if (v_res->>'total_returned')::integer is distinct from 1
     or v_res#>>'{rows,0,id}' is distinct from v_d::text then
    raise exception 'a 4-day window must keep only D: %', v_res;
  end if;
  reset role;

  perform pg_temp.as_v300_user(v_customer);
  begin
    perform public.staff_list_returned_customers_v300(v_business,60,30);
    raise exception 'a customer listed returned customers';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- ---- 3. redemption counts ----
  -- Redemption rows are branch-enforced (enforce_loyalty_redemption_branch_v94); reuse the
  -- auto-created default branch when the businesses trigger already made one.
  select id into v_branch from public.branches
   where business_id=v_business and active limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name,active,is_default)
    values(v_business,'V300 Branch',true,true) returning id into v_branch;
  end if;
  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
  values (v_r1,v_business,'V300 Reward One','V300 Reward One','V300 Reward One','manual_item',100,0,0,true,1),
         (v_r2,v_business,'V300 Reward Two','V300 Reward Two','V300 Reward Two','manual_item',200,0,0,true,2);
  -- Seed as the chain superuser: enforce_loyalty_redemption_branch_v94 bypasses only when
  -- no JWT is in scope, and reset role does not clear the claims the earlier steps set.
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  insert into public.loyalty_redemptions(business_id,client_id,reward_id,reward_name,
                                         points_spent,credit_cents) values
    (v_business,v_client,v_r1,'V300 Reward One',100,0),
    (v_business,v_a,v_r1,'V300 Reward One',100,0),
    (v_business,v_d,v_r2,'V300 Reward Two',200,0),
    (v_business,v_client,null,'Points to credit',500,500);

  perform pg_temp.as_v300_user(v_owner);
  v_counts := public.business_reward_redemption_counts_v300(v_business);
  if (v_counts#>>array['rewards',v_r1::text])::integer is distinct from 2
     or (v_counts#>>array['rewards',v_r2::text])::integer is distinct from 1
     or (v_counts->>'classic')::integer is distinct from 1
     or (v_counts->>'total')::integer is distinct from 4 then
    raise exception 'redemption counts must count real rows exactly: %', v_counts;
  end if;
  reset role;

  perform pg_temp.as_v300_user(v_customer);
  begin
    perform public.business_reward_redemption_counts_v300(v_business);
    raise exception 'a customer read reward redemption counts';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- ---- ACL floor ----
  if has_function_privilege('anon','public.customer_get_referral_card_v300(text)','execute')
     or has_function_privilege('anon','public.staff_list_returned_customers_v300(uuid,integer,integer)','execute')
     or has_function_privilege('anon','public.business_reward_redemption_counts_v300(uuid)','execute') then
    raise exception 'anon must hold no execute on the v300 readbacks';
  end if;

  raise notice 'v300 growth readbacks: all assertions passed';
end
$v300_test$;

rollback;
