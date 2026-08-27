-- Rollback-only acceptance for nestly_v566 — one answer about what a customer can claim.
-- Run: supabase db query --linked -f db/tests/v566_one_claimable_answer.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: the presentation reads app.reward_availability_v432, drops only the two
--       lifecycle states it cannot qualify, no longer carries the un-gated
--       `reward.active and not reward.paused` predicate, and gates its tier ladder on
--       app.programme_running_v371 plus the effective window.
--   02  end to end, rolled back: one tenant, four rewards — A live on the ACTIVE points spine,
--       B on an INACTIVE spine, C past its claim_available_until, D whose published version row
--       is inactive. The presentation's rewards_json must be exactly {A}. Two control rows
--       prove the fixture is not vacuous: the old predicate would have returned all four, and
--       a tier on a switched-off ladder disappears.
--   03  regression on REAL data, read only: for every prod business with a verified customer,
--       impersonate that customer, call the patched presentation, and compare the reward ids it
--       returns against app.reward_availability_v432's own answer. Extras must be 0 and
--       omissions must be 0. A third, informational row counts what the UNPATCHED predicate
--       would have shown wrongly, so a green 03a can never mean "the query found nothing".
--
-- ROLLBACK: reverting v566 means restoring `from public.loyalty_rewards reward where
-- reward.business_id=p_business and reward.active and not reward.paused` and dropping the two
-- tier gates. Only appropriate if the owner decides the customer's home screen SHOULD advertise
-- gifts the counter refuses — which re-opens the recorded defect (9 unclaimable rewards on six
-- tenants, listed beside the reward page that hides them).

begin;

create temp table _r(check_id text, value text) on commit drop;

-- ============ 01 shape ========================================================================
do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.customer_get_business_presentation_v95(uuid,uuid,text)'::regprocedure);
  insert into _r values ('01 function shape',
    case when position('app.reward_availability_v432(p_business,v_client,now())' in v_def) = 0
      then 'FAIL: the rewards block does not delegate to the catalogue core'
      when position('core.availability not in (''not_started'',''ended'')' in v_def) = 0
      then 'FAIL: the lifecycle filter is missing or is filtering the wrong states'
      when position('where reward.business_id=p_business and reward.active and not reward.paused' in v_def) > 0
      then 'FAIL: the un-gated rewards predicate is still there'
      when position('app.programme_running_v371(p_business,''tiers'')' in v_def) = 0
      then 'FAIL: the tier ladder is not gated on the owner''s Tiers switch'
      when position('and (expires_at is null or expires_at>now())' in v_def) = 0
      then 'FAIL: the tier effective window is not applied'
      when position('app.client_points_balance_v409(p_business, v_client)' in v_def) = 0
      then 'FAIL: the v544 balance shape was lost'
      else 'OK' end);
end
$shape$;

-- ============ 02 end to end, rolled back ======================================================
do $endtoend$
declare
  v_biz    uuid := 'c0de0566-0000-4000-8000-000000000001';
  v_ver    uuid := 'c0de0566-0000-4000-8000-000000000002';
  v_branch uuid;
  v_client uuid := 'c0de0566-0000-4000-8000-000000000004';
  v_user   uuid := 'c0de0566-0000-4000-8000-000000000005';
  v_ident  uuid := 'c0de0566-0000-4000-8000-000000000006';
  v_link   uuid := 'c0de0566-0000-4000-8000-000000000007';
  v_a      uuid := 'c0de0566-0000-4000-8000-00000000000a';
  v_b      uuid := 'c0de0566-0000-4000-8000-00000000000b';
  v_c      uuid := 'c0de0566-0000-4000-8000-00000000000c';
  v_d      uuid := 'c0de0566-0000-4000-8000-00000000000d';
  v_points uuid; v_stamps uuid;
  v_json   jsonb; v_names text; v_old text; v_tier jsonb;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_user,'authenticated','authenticated',
    'v566-'||v_user||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status)
  values (v_ident,v_user,'active');

  -- AUTO-SEED TRAP: the businesses insert already creates a default branch and a brand
  -- presentation row, so both of those are taken as found rather than inserted again.
  insert into public.businesses(id,name,slug,industry)
  values (v_biz,'v566 fixture','v566-fixture-rolled-back','fnb');
  insert into public.business_brand_presentation_v95(business_id,hero_color)
  values (v_biz,'#C43D32')
  on conflict (business_id) do update set hero_color='#C43D32';
  select id into v_branch from public.branches
   where business_id=v_biz and active order by is_default desc,created_at,id limit 1;
  if v_branch is null then
    v_branch := 'c0de0566-0000-4000-8000-000000000003';
    insert into public.branches(id,business_id,name,timezone,is_default,active)
    values (v_branch,v_biz,'v566 branch','Asia/Singapore',true,true);
  end if;
  insert into public.clients(id,business_id,full_name)
  values (v_client,v_biz,'v566 customer');
  -- app.v31_link_immutable_guard refuses any link the claim route did not announce; the fixture
  -- announces itself the same way the real route does rather than dropping the guard.
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at)
  values (v_link,v_biz,v_ident,v_user,v_client,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- The businesses insert auto-seeds the spine; assert the switches explicitly rather than
  -- trusting the seed's defaults. POINTS on, STAMPS off, TIERS off.
  insert into public.loyalty_programs(business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode,
    configuration_status)
  values (v_biz,'points','classic',true,1,100,500,'visits','none','published')
  on conflict (business_id) do update set kind='points',loyalty_model='classic',active=true;
  insert into public.business_programmes(business_id,kind,active,sort)
  values (v_biz,'points',true,1),(v_biz,'tiers',false,2),(v_biz,'stamps',false,3)
  on conflict (business_id,kind) do update set active=excluded.active;
  select id into v_points from public.business_programmes where business_id=v_biz and kind='points';
  select id into v_stamps from public.business_programmes where business_id=v_biz and kind='stamps';

  insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash)
  values (v_ver,v_biz,
    (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
    'draft',md5('v566-fixture'));
  update public.businesses set active_config_version_id=v_ver where id=v_biz;
  update public.loyalty_programs set current_config_version_id=v_ver where business_id=v_biz;

  -- A live gift on the running programme; B on the switched-off one; C whose window closed
  -- yesterday; D whose published version row is inactive (withdrawn without being deleted).
  insert into public.loyalty_rewards(id,business_id,programme_id,name,customer_name,internal_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort)
  values (v_a,v_biz,v_points,'v566 A','v566 A','v566 A','manual_item',10,0,0,true,false,0),
         (v_b,v_biz,v_stamps,'v566 B','v566 B','v566 B','manual_item',5,0,0,true,false,1),
         (v_c,v_biz,v_points,'v566 C','v566 C','v566 C','manual_item',10,0,0,true,false,2),
         (v_d,v_biz,v_points,'v566 D','v566 D','v566 D','manual_item',10,0,0,true,false,3);
  insert into public.loyalty_reward_versions(config_version_id,business_id,reward_id,programme_id,
    active,cost_points,customer_name,internal_name,fulfillment_kind,credit_cents,
    estimated_cost_cents,sort,claim_available_until)
  values (v_ver,v_biz,v_a,v_points,true ,10,'v566 A','v566 A','manual_item',0,0,0,null),
         (v_ver,v_biz,v_b,v_stamps,true , 5,'v566 B','v566 B','manual_item',0,0,1,null),
         (v_ver,v_biz,v_c,v_points,true ,10,'v566 C','v566 C','manual_item',0,0,2,now()-interval '1 day'),
         (v_ver,v_biz,v_d,v_points,false,10,'v566 D','v566 D','manual_item',0,0,3,null);

  -- A tier the old code would have shown: the ladder is switched OFF for this tenant.
  insert into public.loyalty_tiers(business_id,name,threshold,sort)
  values (v_biz,'v566 Gold',0,0);

  -- The control: what the pre-v566 predicate returned. Four rewards, three of them unclaimable.
  select string_agg(r.name,',' order by r.sort) into v_old
    from public.loyalty_rewards r
   where r.business_id=v_biz and r.active and not r.paused;
  insert into _r values ('02a control — the old predicate showed all four',
    case when v_old='v566 A,v566 B,v566 C,v566 D' then 'OK (v566 A,v566 B,v566 C,v566 D)'
         else 'FAIL: fixture did not reproduce the defect, got '||coalesce(v_old,'NULL') end);

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_user,'role','authenticated')::text, true);
  v_json := public.customer_get_business_presentation_v95(v_biz);
  perform set_config('request.jwt.claims','',true);

  select coalesce(string_agg(elem->>'name',',' order by elem->>'name'),'')
    into v_names
    from jsonb_array_elements(v_json->'catalogue'->'rewards') elem;
  insert into _r values ('02b the presentation returns exactly {A}',
    case when v_names='v566 A' then 'OK'
         else 'FAIL: got ['||v_names||'] — expected [v566 A]' end);

  insert into _r values ('02c the surviving reward carries the published version''s price',
    case when (v_json->'catalogue'->'rewards'->0->'metadata'->>'cost_points')='10' then 'OK'
         else 'FAIL: '||coalesce(v_json->'catalogue'->'rewards'->0->'metadata'->>'cost_points','NULL') end);

  v_tier := v_json->'programme'->'tier';
  insert into _r values ('02d a switched-off ladder grants no tier',
    case when v_tier->'current' = 'null'::jsonb or v_tier->'current' is null then 'OK'
         else 'FAIL: '||v_tier::text end);
exception when others then
  perform set_config('request.jwt.claims','',true);
  insert into _r values ('02b the presentation returns exactly {A}', 'FAIL: '||sqlerrm);
end
$endtoend$;

-- ============ 03 regression on real data (read only) ==========================================
do $regress$
declare
  r record; v_json jsonb;
  v_shown uuid[]; v_expected uuid[];
  v_extra integer:=0; v_missing integer:=0; v_seen integer:=0; v_errs text:='';
  v_would_have integer:=0;
begin
  for r in
    select distinct on (link.business_id)
           link.business_id, link.auth_user_id, link.client_id
      from public.customer_links link
      join public.customer_identities ident
        on ident.id=link.identity_id and ident.auth_user_id=link.auth_user_id
       and ident.status='active'
      join public.business_brand_presentation_v95 brand on brand.business_id=link.business_id
     where link.state='verified'
       and link.business_id <> 'c0de0566-0000-4000-8000-000000000001'::uuid
       and exists (select 1 from public.branches br
                    where br.business_id=link.business_id and br.active)
     order by link.business_id, link.created_at, link.id
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',r.auth_user_id,'role','authenticated')::text, true);
    begin
      v_json := public.customer_get_business_presentation_v95(r.business_id);
    exception when others then
      v_errs := v_errs||' ['||r.business_id::text||': '||sqlerrm||']';
      continue;
    end;
    v_seen := v_seen + 1;
    select coalesce(array_agg((elem->>'id')::uuid),'{}') into v_shown
      from jsonb_array_elements(v_json->'catalogue'->'rewards') elem;
    select coalesce(array_agg(core.reward_id),'{}') into v_expected
      from app.reward_availability_v432(r.business_id,r.client_id,now()) core
     where core.availability not in ('not_started','ended');
    select v_extra + count(*) into v_extra
      from unnest(v_shown) x where not (x = any(v_expected));
    select v_missing + count(*) into v_missing
      from unnest(v_expected) x where not (x = any(v_shown));
    select v_would_have + count(*) into v_would_have
      from public.loyalty_rewards live
     where live.business_id=r.business_id and live.active and not live.paused
       and not (live.id = any(v_expected));
  end loop;
  perform set_config('request.jwt.claims','',true);

  insert into _r values ('03a no business advertises a reward the catalogue core refuses',
    case when v_extra=0 then 'OK ('||v_seen||' tenant(s) probed'||
           case when v_errs='' then '' else '; unreadable:'||v_errs end||')'
         else 'FAIL: '||v_extra||' extra reward(s)' end);
  insert into _r values ('03b no business hides a reward the catalogue core offers',
    case when v_missing=0 then 'OK' else 'FAIL: '||v_missing||' missing reward(s)' end);
  insert into _r values ('03c control — rewards the pre-v566 predicate would have mis-shown',
    case when v_seen=0 then 'FAIL: no tenant was probed, 03a proves nothing'
         else 'INFO: '||v_would_have end);
end
$regress$;

select * from _r order by check_id;

rollback;
