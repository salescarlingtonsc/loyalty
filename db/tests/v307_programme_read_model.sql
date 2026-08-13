-- Rollback-only v307 acceptance: the W1 programme read model answers the four flags from
-- today's columns, mirrors the live capabilities function, and writes nothing.
--
-- app.business_programmes_v307 is the contract every later wave of the four-programme plan is
-- measured against: W2 backfills public.business_programmes FROM it, and W3-W5 diff their own
-- answers AGAINST it. So this suite does three jobs.
--
--   1. It WALKS one fixture tenant through the mode/model shapes that exist in production and
--      pins the answer for each (steps 1-8). Step 6 pins an ODDITY on purpose — a stamps firm
--      with points_mode NULL and a leftover tier ladder answers tiers=true, because the live
--      customer_portal_capabilities coalesces a NULL mode to 'tiers' and never asks the model.
--      Mirroring means mirroring; the read model may not quietly out-think the surface it has to
--      reproduce, or it cannot be used to prove a later wave changed nothing. The shape the
--      2026-08-13 tenant survey actually found in production is step 5 (stamps,
--      points_mode='redeem', leftover tier rows), and there the coalesce suppresses the stale
--      ladder correctly: stamps=true, tiers=false. The oddity is resolved at W2, where the spine
--      records what the owner switched on instead of inferring it.
--   2. It proves the MIRROR live (step 9) for a CLASSIC-MODEL firm: for every points_mode in
--      the vocabulary (both / tiers / redeem / null) the read model's tiers flag equals
--      customer_portal_capabilities(slug)->>'tiers', and — with the fixture holding a nonempty
--      classic redeem pair — its points flag equals the 'rewards' capability. Both sides are
--      computed inside this one transaction, so the assertion cannot drift from the deployed
--      definition. This step therefore requires v306 (the both-mode tiers patch) to be applied:
--      against a pre-v306 database the 'both' row SHOULD fail, and that failure is the mirror
--      contract working. Stamps-model firms sit deliberately OUTSIDE this comparison: the read
--      model is model-exclusive on points (migration divergence 3), so a stamps firm with a
--      published catalogue answers points=false while the live rewards capability answers true
--      — that pair differing is the documented design, not a parity failure.
--   3. It proves the wave is ZERO-WRITE by construction (step 10): the function is declared
--      STABLE (provolatile='s'), is SECURITY INVOKER (prosecdef=false), and its stored definition
--      contains no insert/update/delete/truncate/merge token at all.
--
-- Steps 1-8 and 10-11 deliberately run with NO customer identity and NO customer link in
-- existence. That is divergence (1) from customer_portal_capabilities being asserted rather than
-- described: this is per-business programme truth, not a per-customer presentation answer, so it
-- must answer for a business nobody has ever linked to. The verified link is seeded only at step
-- 9, where a real capabilities call needs it.
--
-- Fixture note: the wizard writes kind='points' on loyalty_programs even for the stamps model
-- (app.js row builders), so the fixture keeps kind='points' throughout and moves loyalty_model
-- alone — the production shape. The read model never reads kind.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v307_programme_read_model.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v307_out(seq integer, step text, outcome text) on commit drop;

-- Customer-context calls need a real JWT; privileged seeding needs NO JWT, because several write
-- guards (branch enforcement, link insertion) bypass only when no claims are in scope.
create or replace function pg_temp.as_v307_user(
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
grant execute on function pg_temp.as_v307_user(uuid,text) to public;

create or replace function pg_temp.as_v307_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v307_system() to public;

-- The four flags as one comparable object. The read model is SECURITY INVOKER, so it is always
-- read here in the system context: a backfill or a wave diff runs with full visibility, and a
-- test that read it through a tenant session would be asserting RLS, not the predicates.
create or replace function pg_temp.v307_flags(p_business uuid) returns jsonb
language sql stable as $$
  select jsonb_object_agg(programme.kind, programme.running)
    from app.business_programmes_v307(p_business) programme;
$$;
grant execute on function pg_temp.v307_flags(uuid) to public;

do $v307_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_slug text:='v307-programmes-'||substr(gen_random_uuid()::text,1,8);
  v_expected_points jsonb:=jsonb_build_object(
    'points',true,'tiers',false,'stamps',false,'referral',false);
  v_expected_points_tiers jsonb:=jsonb_build_object(
    'points',true,'tiers',true,'stamps',false,'referral',false);
  v_expected_tiers jsonb:=jsonb_build_object(
    'points',false,'tiers',true,'stamps',false,'referral',false);
  v_expected_stamps jsonb:=jsonb_build_object(
    'points',false,'tiers',false,'stamps',true,'referral',false);
  v_expected_stamps_tiers jsonb:=jsonb_build_object(
    'points',false,'tiers',true,'stamps',true,'referral',false);
  v_flags jsonb;
  v_before jsonb;
  v_after jsonb;
  v_caps jsonb;
  v_mode text;
  v_detail text:='';
  v_ok boolean:=true;
  v_def text;
  v_volatile text;
  v_secdef boolean;
  v_missing uuid:=gen_random_uuid();
  v_kinds text[];
  v_rows integer;
  v_true_rows integer;
  v_null_rows integer;
begin
  perform pg_temp.as_v307_system();

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v307-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
     'v307-customer-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now());

  -- No owner session exists yet, so the business insert is a system transition. The trigger it
  -- fires writes the pending workspace control + lifecycle pair that
  -- app.business_workspace_open_v94 reads, so the fixture UPDATEs the decision to approved the
  -- way platform review would rather than inserting its own.
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values(v_business,'V307 programme read model fixture',v_slug,'retail','SGD',
         array['dashboard','clients','sales','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v307 rollback fixture'
   where business_id=v_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(v_business)
  on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false
   where business_id=v_business;

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V307 Owner',true);

  -- A classic points programme with a real redeem pair, so the 'rewards' capability step 9
  -- compares against is true whenever its mode gate allows it.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    redeem_points,reward_credit_cents,tier_basis
  ) values(v_business,'points',true,'classic','published',100,500,'visits');

  -- ---- 1. classic + redeem, no ladder configured: points only ----
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(1,'classic_redeem_points_only',
    case when v_flags=v_expected_points
      then 'PASS '||v_flags::text
      else 'FAIL expected '||v_expected_points::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 2. classic + both + a ladder: points AND tiers ----
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort) values
    (v_business,'Silver',0,1,1),
    (v_business,'Gold',5,1,2),
    (v_business,'Diamond',15,1.5,3);
  update public.businesses set points_mode='both' where id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(2,'classic_both_points_and_tiers',
    case when v_flags=v_expected_points_tiers
      then 'PASS '||v_flags::text
      else 'FAIL expected '||v_expected_points_tiers::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 3. classic + tiers: the ladder only, points are not spendable ----
  update public.businesses set points_mode='tiers' where id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(3,'classic_tiers_ladder_only',
    case when v_flags=v_expected_tiers
      then 'PASS '||v_flags::text
      else 'FAIL expected '||v_expected_tiers::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 4. classic + NULL mode: BOTH, the asymmetric-coalesce truth ----
  -- points coalesces an unchosen mode to 'redeem' and tiers coalesces it to 'tiers', so a firm
  -- that never chose answers yes to both. v229 backfilled 'redeem' onto every firm that had a
  -- programme row, so this survives only where no programme was ever configured.
  update public.businesses set points_mode=null where id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(4,'classic_null_mode_points_and_tiers',
    case when v_flags=v_expected_points_tiers
      then 'PASS '||v_flags::text
      else 'FAIL expected '||v_expected_points_tiers::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 5. stamps + redeem + a LEFTOVER ladder: stamps only. The live production shape. ----
  update public.loyalty_programs
     set loyalty_model='stamps',stamp_per_cents=500,stamp_target=10
   where business_id=v_business;
  update public.businesses set points_mode='redeem' where id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(5,'stamps_redeem_suppresses_leftover_ladder',
    case when v_flags=v_expected_stamps
      then 'PASS '||v_flags::text
      else 'FAIL expected '||v_expected_stamps::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 6. stamps + NULL mode + a leftover ladder: the mirrored ODDITY, pinned on purpose ----
  update public.businesses set points_mode=null where id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(6,'stamps_null_mode_mirrors_capabilities_oddity',
    case when v_flags=v_expected_stamps_tiers
      then 'PASS mirror held (tiers=true is the capabilities answer too) '||v_flags::text
      else 'FAIL expected '||v_expected_stamps_tiers::text||' got '||coalesce(v_flags::text,'null') end);

  -- ---- 7. referral flips its own flag and NOTHING else ----
  update public.loyalty_programs set loyalty_model='classic' where business_id=v_business;
  update public.businesses set points_mode='redeem' where id=v_business;
  v_before:=pg_temp.v307_flags(v_business);
  insert into public.referral_programs(business_id,enabled,reward_cents,min_spend_cents)
  values(v_business,true,1000,0);
  v_after:=pg_temp.v307_flags(v_business);
  insert into v307_out values(7,'referral_is_independent',
    case when coalesce((v_before->>'referral')::boolean,true)=false
          and coalesce((v_after->>'referral')::boolean,false)=true
          and (v_before-'referral'::text)=(v_after-'referral'::text)
      then 'PASS only referral moved: '||v_before::text||' -> '||v_after::text
      else 'FAIL '||coalesce(v_before::text,'null')||' -> '||coalesce(v_after::text,'null') end);

  -- ---- 8. an INACTIVE programme row zeroes points/tiers/stamps and leaves referral alone ----
  update public.businesses set points_mode=null where id=v_business;
  v_before:=pg_temp.v307_flags(v_business);
  update public.loyalty_programs set active=false where business_id=v_business;
  v_after:=pg_temp.v307_flags(v_business);
  -- stamps cannot be true at the same time as points, so the stamps half of the claim is proven
  -- by moving the inactive row to the stamps model and watching it stay false.
  update public.loyalty_programs set loyalty_model='stamps' where business_id=v_business;
  v_flags:=pg_temp.v307_flags(v_business);
  insert into v307_out values(8,'inactive_programme_zeroes_loyalty_not_referral',
    case when v_before=jsonb_build_object(
                'points',true,'tiers',true,'stamps',false,'referral',true)
          and v_after=jsonb_build_object(
                'points',false,'tiers',false,'stamps',false,'referral',true)
          and v_flags=jsonb_build_object(
                'points',false,'tiers',false,'stamps',false,'referral',true)
      then 'PASS active gate: '||v_before::text||' -> '||v_after::text||' -> stamps model '||v_flags::text
      else 'FAIL '||coalesce(v_before::text,'null')||' -> '||coalesce(v_after::text,'null')
             ||' -> '||coalesce(v_flags::text,'null') end);

  -- ---- 9. PARITY with the deployed customer_portal_capabilities, computed side by side ----
  update public.loyalty_programs
     set active=true,loyalty_model='classic'
   where business_id=v_business;

  -- The capability call is customer-scoped: it needs the platform wallet flag, an active identity
  -- and a VERIFIED link. Seeded here and nowhere earlier, so steps 1-8 stand as proof that the
  -- read model needs none of it.
  insert into app.platform_feature_flags(feature_key,enabled) values
    ('customer_wallet',true)
  on conflict (feature_key) do update set enabled=true,changed_at=now();
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration');
  insert into public.clients(id,business_id,full_name,phone)
  values(v_client,v_business,'V307 Member','+6580003070');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  foreach v_mode in array array['both','tiers','redeem',null]::text[]
  loop
    update public.businesses set points_mode=v_mode where id=v_business;
    v_flags:=pg_temp.v307_flags(v_business);
    perform pg_temp.as_v307_user(v_customer);
    v_caps:=public.customer_portal_capabilities(v_slug);
    perform pg_temp.as_v307_system();
    if coalesce((v_flags->>'tiers')::boolean,false)
         <> coalesce((v_caps->>'tiers')::boolean,false)
       or coalesce((v_flags->>'points')::boolean,false)
         <> coalesce((v_caps->>'rewards')::boolean,false) then
      v_ok:=false;
    end if;
    v_detail:=v_detail||coalesce(v_mode,'null')||': tiers '
      ||coalesce((v_flags->>'tiers'),'null')||'/'||coalesce((v_caps->>'tiers'),'null')
      ||' points-vs-rewards '
      ||coalesce((v_flags->>'points'),'null')||'/'||coalesce((v_caps->>'rewards'),'null')||'; ';
  end loop;
  insert into v307_out values(9,'mirrors_customer_portal_capabilities',
    case when v_ok
      then 'PASS read model = capabilities for every mode — '||v_detail
      else 'FAIL model/capabilities disagree — '||v_detail end);

  -- ---- 10. zero-write proof: STABLE, invoker, and no write token in the stored definition ----
  select proc.provolatile::text,proc.prosecdef,pg_get_functiondef(proc.oid)
    into strict v_volatile,v_secdef,v_def
    from pg_catalog.pg_proc proc
   where proc.oid='app.business_programmes_v307(uuid)'::regprocedure;
  insert into v307_out values(10,'read_model_writes_nothing',
    case when v_volatile='s' and v_secdef=false
          and v_def !~* '\m(insert|update|delete|truncate|merge)\M'
      then 'PASS provolatile=s prosecdef=false, no write token in the definition'
      else 'FAIL provolatile='||v_volatile||' prosecdef='||v_secdef::text
             ||' write_token='||(v_def ~* '\m(insert|update|delete|truncate|merge)\M')::text end);

  -- ---- 11. a business that does not exist still gets four rows, in the pinned order, all false ----
  select array_agg(programme.kind order by programme.ord),
         count(*)::integer,
         (count(*) filter (where programme.running))::integer,
         (count(*) filter (where programme.running is null))::integer
    into strict v_kinds,v_rows,v_true_rows,v_null_rows
    from app.business_programmes_v307(v_missing)
      with ordinality as programme(kind,running,ord);
  insert into v307_out values(11,'unknown_business_still_answers_four_false_rows',
    case when v_rows=4 and v_true_rows=0 and v_null_rows=0
          and v_kinds=array['points','tiers','stamps','referral']
      then 'PASS 4 rows, all false, order '||v_kinds::text
      else 'FAIL rows='||v_rows||' true='||v_true_rows||' null='||v_null_rows
             ||' kinds='||coalesce(v_kinds::text,'null') end);
end
$v307_test$;

reset role;

select seq, step, outcome from v307_out order by seq;

rollback;
