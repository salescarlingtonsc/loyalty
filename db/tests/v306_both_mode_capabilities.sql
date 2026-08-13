-- Rollback-only v306 acceptance: a firm running points AND tiers shows BOTH programmes.
--
-- v239 made businesses.points_mode='both' legal, but customer_portal_capabilities still
-- decided the tier ladder with an equality against 'tiers', so a both-mode firm answered
-- tiers=false and its customers never saw the ladder the owner had published. This suite
-- walks the whole mode vocabulary against one fixture tenant:
--   'both'   -> the ladder AND the reward catalogue, with the mode reported;
--   'tiers'  -> the ladder only (v229/v231 behaviour, unchanged);
--   'redeem' -> the catalogue only (unchanged);
--   null     -> an unchosen firm still shows the tiers it has (unchanged).
-- It then proves the v229 redemption gate still refuses ONLY 'tiers' — the gate and the
-- 'rewards' capability were already right for 'both' and are deliberately not patched — and
-- pins the patched function text so a later rebuild from an older source cannot revert it.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v306_both_mode_capabilities.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v306_out(seq integer, step text, outcome text) on commit drop;

-- Customer-context calls need a real JWT; privileged seeding needs NO JWT, because several
-- write guards (branch enforcement, link insertion) bypass only when no claims are in scope.
create or replace function pg_temp.as_v306_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v306_user(uuid,text) to public;

create or replace function pg_temp.as_v306_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v306_system() to public;

do $v306_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_slug text:='v306-both-'||substr(gen_random_uuid()::text,1,8);
  v_caps jsonb;
  v_msg text;
  v_def text;
  v_old text:='and coalesce(v_points_mode,''tiers'') = ''tiers''';
  v_new text:='and coalesce(v_points_mode,''tiers'') in (''tiers'',''both'')';
  v_old_count integer;
  v_new_count integer;
begin
  perform pg_temp.as_v306_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v306-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
     'v306-customer-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now());

  -- No owner session exists yet, so the business insert is a system transition. The trigger it
  -- fires writes the pending workspace control + lifecycle pair that
  -- app.business_workspace_open_v94 reads, so the fixture UPDATEs the decision to approved the
  -- way platform review would rather than inserting its own.
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values(v_business,'V306 both-mode fixture',v_slug,'retail','SGD',
         array['dashboard','clients','sales','loyalty'],'both');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v306 rollback fixture'
   where business_id=v_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_business)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id=v_business;

  -- The wallet context and the redemption door are both platform-flag gated; a firm-level
  -- fixture proves nothing if the platform switch is off.
  insert into app.platform_feature_flags(feature_key,enabled) values
    ('customer_wallet',true),
    ('customer_qr_redemption',true)
  on conflict (feature_key) do update set enabled=true,changed_at=now();

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V306 Owner',true);

  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration');
  insert into public.clients(id,business_id,full_name,phone)
  values(v_client,v_business,'V306 Member','+6580003060');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- A classic points programme (so 'rewards' can be true) with a VISITS ladder, which is what
  -- 'both' means: the two programmes measure different things and never share a currency.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents,tier_basis
  ) values(v_business,'points',true,'classic','published',100,500,'visits');
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort) values
    (v_business,'Bronze',0,1,1),
    (v_business,'Silver',5,1,2),
    (v_business,'Gold',15,1.5,3);
  insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
  values(v_business,true)
  on conflict (business_id) do update set redemption_enabled=true;

  -- ---- 1. both: the ladder AND the catalogue, with the mode reported ----
  perform pg_temp.as_v306_user(v_customer);
  v_caps:=public.customer_portal_capabilities(v_slug);
  perform pg_temp.as_v306_system();
  insert into v306_out values(1,'both_shows_tiers_and_rewards',
    case when coalesce((v_caps->>'tiers')::boolean,false)
          and coalesce((v_caps->>'rewards')::boolean,false)
          and v_caps->>'points_mode'='both'
      then 'PASS tiers=true rewards=true points_mode=both'
      else 'FAIL '||coalesce(v_caps::text,'null') end);

  -- ---- 2. tiers: unchanged — ladder yes, catalogue no ----
  update public.businesses set points_mode='tiers' where id=v_business;
  perform pg_temp.as_v306_user(v_customer);
  v_caps:=public.customer_portal_capabilities(v_slug);
  perform pg_temp.as_v306_system();
  insert into v306_out values(2,'tiers_mode_unchanged',
    case when coalesce((v_caps->>'tiers')::boolean,false)
          and coalesce((v_caps->>'rewards')::boolean,true)=false
      then 'PASS tiers=true rewards=false'
      else 'FAIL '||coalesce(v_caps::text,'null') end);

  -- ---- 3. redeem: unchanged — catalogue yes, ladder no ----
  update public.businesses set points_mode='redeem' where id=v_business;
  perform pg_temp.as_v306_user(v_customer);
  v_caps:=public.customer_portal_capabilities(v_slug);
  perform pg_temp.as_v306_system();
  insert into v306_out values(3,'redeem_mode_unchanged',
    case when coalesce((v_caps->>'tiers')::boolean,true)=false
          and coalesce((v_caps->>'rewards')::boolean,false)
      then 'PASS tiers=false rewards=true'
      else 'FAIL '||coalesce(v_caps::text,'null') end);

  -- ---- 4. unchosen: v231's "nothing has been put away" behaviour is untouched ----
  update public.businesses set points_mode=null where id=v_business;
  perform pg_temp.as_v306_user(v_customer);
  v_caps:=public.customer_portal_capabilities(v_slug);
  perform pg_temp.as_v306_system();
  insert into v306_out values(4,'unchosen_mode_still_shows_tiers',
    case when coalesce((v_caps->>'tiers')::boolean,false)
      then 'PASS tiers=true'
      else 'FAIL '||coalesce(v_caps::text,'null') end);

  -- ---- 5. the v229 redemption gate still refuses tiers mode ----
  update public.businesses set points_mode='tiers' where id=v_business;
  perform pg_temp.as_v306_user(v_customer);
  v_msg:='';
  begin
    perform public.customer_create_redemption_intent_v89(
      v_business,null::uuid,gen_random_uuid(),'classic_points');
  exception when others then v_msg:=sqlerrm;
  end;
  perform pg_temp.as_v306_system();
  insert into v306_out values(5,'tiers_mode_refuses_redemption',
    case when v_msg like '%count toward membership tiers%'
      then 'PASS gate fired: '||v_msg
      else 'FAIL expected the tiers-mode refusal, got: '
             ||coalesce(nullif(v_msg,''),'no error at all') end);

  -- ---- 6. ...and does NOT refuse both mode. Any LATER failure is fine here; this asserts
  --         only that the points-mode gate is not what fired.
  update public.businesses set points_mode='both' where id=v_business;
  perform pg_temp.as_v306_user(v_customer);
  v_msg:='';
  begin
    perform public.customer_create_redemption_intent_v89(
      v_business,null::uuid,gen_random_uuid(),'classic_points');
  exception when others then v_msg:=sqlerrm;
  end;
  perform pg_temp.as_v306_system();
  insert into v306_out values(6,'both_mode_does_not_refuse_redemption',
    case when v_msg not like '%membership tiers%'
      then 'PASS no points-mode refusal (call outcome: '
             ||coalesce(nullif(v_msg,''),'succeeded')||')'
      else 'FAIL the tiers-mode gate fired under both: '||v_msg end);

  -- ---- 7. function shape: the widened predicate is there once, the old equality is gone ----
  select pg_get_functiondef(
    'public.customer_portal_capabilities(text)'::regprocedure
  ) into strict v_def;
  v_new_count:=(length(v_def)-length(replace(v_def,v_new,'')))/length(v_new);
  v_old_count:=(length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  insert into v306_out values(7,'patched_function_shape',
    case when v_new_count=1 and v_old_count=0
      then 'PASS widened predicate x1, old equality x0'
      else 'FAIL widened='||v_new_count||' old='||v_old_count end);
end
$v306_test$;

reset role;

select seq, step, outcome from v306_out order by seq;

rollback;
