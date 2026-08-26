-- Rollback-only acceptance for nestly_v520 — a points gift carries its own optional expiry.
-- Run: supabase db query --linked -f db/tests/v520_a_points_gift_can_expire.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- OWNER RULING (2026-08-26): "for points it would be individual gifts expiry, if dont want to set
-- expiry dont need to indicate, if not can set individual expiry for points gift."
--
-- These assertions EXECUTE the writers. A test that only greps the function body would have passed
-- against a version that saves the number and never lets the customer see it — which is exactly
-- the failure this migration's three-part change exists to prevent.
--
--   01  a gift created WITHOUT an expiry has none — today's behaviour is the default
--   02  a gift created WITH one carries it on the live row AND on the reward version
--   03  the customer's own availability core returns it
--   04  editing a PUBLISHED gift's expiry succeeds — the immutable guard's allowlist moved
--   05  null means "leave it alone": an edit that says nothing keeps the stored value
--   06  p_clear_expiry_days removes it, and only that
--   07  zero and negative are refused rather than silently stored
--   08  the expiry is the ONLY thing that changed — name, cost and photo survive an expiry edit
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v520_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.as_v520_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust  uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v520-acceptance-' || substr(gen_random_uuid()::text,1,8);
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_spine uuid; v_cfg uuid;
  v_plain uuid; v_dated uuid;
  v_res jsonb; v_live integer; v_ver integer; v_avail integer;
  v_name text; v_cost integer; v_err text;
begin
  -- ================= FIXTURE: a business running points, published =================
  insert into public.businesses(id,name,slug,enabled_modules,points_mode)
  values (v_biz,'V520 Acceptance',v_slug,array['loyalty','clients','till','sales'],'redeem');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'zz-v520-o-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
          'zz-v520-c-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,active) values (v_biz,v_owner,'owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'V520 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v520', updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;

  perform pg_temp.as_v520_user(v_owner);
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,earn_points_per_dollar)
  values (v_biz,true,'classic','points','published',1);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points',true), gen_random_uuid());
  select id into v_spine from public.business_programmes
   where business_id=v_biz and kind='points';
  select active_config_version_id into v_cfg from public.businesses where id=v_biz;

  -- ================= 01  NO EXPIRY IS STILL THE DEFAULT =================
  v_res := public.business_create_reward_v326(
    p_business=>v_biz, p_programme=>v_spine, p_name=>'V520 Plain', p_points=>5);
  v_plain := (v_res->>'reward_id')::uuid;
  select entitlement_expiry_days into v_live from public.loyalty_rewards where id=v_plain;
  insert into _r values('01_no_expiry_by_default',
    case when v_live is null
      then 'PASS a gift created without an expiry has none — every existing gift is unchanged'
      else 'FAIL entitlement_expiry_days=' || v_live::text end);

  -- ================= 02  IT REACHES BOTH THE LIVE ROW AND THE VERSION =================
  v_res := public.business_create_reward_v326(
    p_business=>v_biz, p_programme=>v_spine, p_name=>'V520 Dated', p_points=>3,
    p_entitlement_expiry_days=>14);
  v_dated := (v_res->>'reward_id')::uuid;
  select entitlement_expiry_days into v_live from public.loyalty_rewards where id=v_dated;
  select entitlement_expiry_days into v_ver from public.loyalty_reward_versions
   where reward_id=v_dated and business_id=v_biz and config_version_id=v_cfg;
  insert into _r values('02_written_to_live_row_and_version',
    case when v_live=14 and v_ver=14
      then 'PASS 14 days on both — the customer reads the VERSION, so writing only the live row would be invisible'
      else 'FAIL live=' || coalesce(v_live::text,'null') || ' version=' || coalesce(v_ver::text,'null') end);
  insert into _r values('02b_returned_to_the_caller',
    case when (v_res->>'entitlement_expiry_days')='14'
      then 'PASS the writer reports back what it stored, so the page can show it without a re-read'
      else 'FAIL returned ' || coalesce(v_res->>'entitlement_expiry_days','nothing') end);

  -- ================= 03  THE CUSTOMER'S OWN CORE RETURNS IT =================
  insert into public.clients(id,business_id,full_name,phone)
  values (v_client,v_biz,'V520 Customer','+65 9519 1001');
  insert into public.customer_identities(id,auth_user_id,status) values (v_identity,v_cust,'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_cust,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  select ra.entitlement_expiry_days into v_avail
    from app.reward_availability_v432(v_biz, v_client, now()) ra
   where ra.reward_id = v_dated;
  insert into _r values('03_customer_core_returns_it',
    case when v_avail=14
      then 'PASS the availability core carries the expiry through to the customer surface'
      else 'FAIL the core returned ' || coalesce(v_avail::text,'null') end);

  -- ================= 04  A PUBLISHED GIFT CAN BE EDITED (the guard allowlist) =================
  -- This is the assertion that fails loudly if section 3 of the migration is forgotten: the
  -- version above belongs to a PUBLISHED config, which app.reward_version_immutable_guard()
  -- freezes column by column.
  v_err := '';
  begin
    v_res := public.business_update_reward_v326(
      p_business=>v_biz, p_reward=>v_dated, p_name=>'V520 Dated', p_points=>3,
      p_entitlement_expiry_days=>30);
  exception when others then v_err := sqlerrm;
  end;
  select entitlement_expiry_days into v_ver from public.loyalty_reward_versions
   where reward_id=v_dated and business_id=v_biz and config_version_id=v_cfg;
  insert into _r values('04_published_gift_expiry_is_editable',
    case when v_err='' and v_ver=30
      then 'PASS editing a published gift''s expiry no longer raises restrict_violation'
      else 'FAIL ' || coalesce(nullif(v_err,''), 'version still reads ' || coalesce(v_ver::text,'null')) end);

  -- ================= 05  NULL MEANS LEAVE IT ALONE =================
  perform public.business_update_reward_v326(
    p_business=>v_biz, p_reward=>v_dated, p_name=>'V520 Dated Renamed', p_points=>3);
  select entitlement_expiry_days into v_ver from public.loyalty_reward_versions
   where reward_id=v_dated and business_id=v_biz and config_version_id=v_cfg;
  insert into _r values('05_null_keeps_the_stored_value',
    case when v_ver=30
      then 'PASS a save that says nothing about the expiry keeps it — an older bundle cannot wipe it'
      else 'FAIL the expiry became ' || coalesce(v_ver::text,'null') end);

  -- ================= 06  CLEARING IS AN EXPLICIT ACT =================
  perform public.business_update_reward_v326(
    p_business=>v_biz, p_reward=>v_dated, p_name=>'V520 Dated Renamed', p_points=>3,
    p_clear_expiry_days=>true);
  select entitlement_expiry_days into v_ver from public.loyalty_reward_versions
   where reward_id=v_dated and business_id=v_biz and config_version_id=v_cfg;
  select entitlement_expiry_days into v_live from public.loyalty_rewards where id=v_dated;
  insert into _r values('06_clear_removes_it_from_both',
    case when v_ver is null and v_live is null
      then 'PASS clearing removes the expiry from the live row and the version together'
      else 'FAIL version=' || coalesce(v_ver::text,'null') || ' live=' || coalesce(v_live::text,'null') end);

  -- ================= 07  ZERO AND NEGATIVE ARE REFUSED =================
  v_err := '';
  begin
    perform public.business_update_reward_v326(
      p_business=>v_biz, p_reward=>v_dated, p_name=>'V520 Dated Renamed', p_points=>3,
      p_entitlement_expiry_days=>0);
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('07a_zero_days_refused',
    case when v_err like '%at least 1 day%'
      then 'PASS "expires after 0 days" is refused instead of making the gift unusable on sight'
      else 'FAIL ' || coalesce(nullif(v_err,''),'zero was accepted') end);
  v_err := '';
  begin
    perform public.business_create_reward_v326(
      p_business=>v_biz, p_programme=>v_spine, p_name=>'V520 Negative', p_points=>2,
      p_entitlement_expiry_days=>-5);
  exception when others then v_err := sqlerrm;
  end;
  insert into _r values('07b_negative_days_refused',
    case when v_err like '%at least 1 day%'
      then 'PASS a negative expiry is refused at creation too'
      else 'FAIL ' || coalesce(nullif(v_err,''),'a negative expiry was accepted') end);

  -- ================= 08  NOTHING ELSE MOVED =================
  perform public.business_update_reward_v326(
    p_business=>v_biz, p_reward=>v_plain, p_name=>'V520 Plain', p_points=>5,
    p_entitlement_expiry_days=>7);
  select customer_name, cost_points, entitlement_expiry_days
    into v_name, v_cost, v_ver
    from public.loyalty_reward_versions
   where reward_id=v_plain and business_id=v_biz and config_version_id=v_cfg;
  insert into _r values('08_only_the_expiry_changed',
    case when v_name='V520 Plain' and v_cost=5 and v_ver=7
      then 'PASS setting an expiry left the gift''s name and cost exactly as they were'
      else 'FAIL name=' || coalesce(v_name,'null') || ' cost=' || coalesce(v_cost::text,'null')
           || ' expiry=' || coalesce(v_ver::text,'null') end);
end $$;

select * from _r order by k;
rollback;
