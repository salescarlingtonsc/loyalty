-- Rollback-only v393 customer tier visibility acceptance suite.
-- Run after the canonical chain through v393 in a disposable database.
--
-- Proves the owner's exclusivity rule end to end at the reader: with points+tiers live a
-- customer sees their tier (paused/deleted rungs invisible, next-rung distance correct); the
-- moment the spine reads stamps-only — the exact shape business_switch_to_stamps_v384 writes —
-- the tier vanishes and the model is 'stamps'. The suite flips the spine directly rather than
-- calling the switch RPC so it needs no auth plumbing; the switch's spine write is asserted
-- verbatim in its own function body ({'stamps',true,'points',false,'tiers',false}).
begin;

do $v393$
declare
  v_owner  uuid := gen_random_uuid();
  v_biz    uuid := gen_random_uuid();
  v_client uuid;
  v_branch uuid;
  v_staff  uuid;
  v_json   jsonb;
begin
  reset role;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
         'v393-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values(v_biz,'V393 tier visibility fixture','v393-tier-'||substr(v_biz::text,1,8),'test',true,array['loyalty']);

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_biz,v_owner,'owner','V393 Owner',true) returning id into v_staff;

  select id into v_branch from public.branches where business_id=v_biz limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name) values(v_biz,'V393 Main') returning id into v_branch;
  end if;

  insert into public.clients(business_id,full_name) values(v_biz,'V393 member') returning id into v_client;

  -- Spine: points + tiers live; stamps off. A trigger on businesses already seeds the spine,
  -- so the suite upserts rather than inserts (first rehearsal failed on the unique key).
  insert into public.business_programmes(business_id,kind,active,sort)
  values (v_biz,'points',true,1),(v_biz,'tiers',true,2),(v_biz,'stamps',false,3)
  on conflict (business_id,kind) do update set active=excluded.active;

  -- Ladder: Bronze 0 · Gold 2 (paused — must be invisible to customers) · Silver 3.
  insert into public.loyalty_tiers(business_id,name,threshold,sort,paused)
  values (v_biz,'Bronze',0,1,false),(v_biz,'Gold',2,2,true),(v_biz,'Silver',3,3,false);

  -- Two valid visits → metric 2 under the default 'visits' basis (no loyalty_programs row, so
  -- the helper's coalesce(tier_basis,'visits') default path is exercised too).
  insert into public.sales(id,business_id,client_id,branch_id,staff_id,kind,amount_cents,occurred_at,note)
  values (gen_random_uuid(),v_biz,v_client,v_branch,v_staff,'quick_sale',1000,clock_timestamp(),'v393 visit 1'),
         (gen_random_uuid(),v_biz,v_client,v_branch,v_staff,'quick_sale',1200,clock_timestamp(),'v393 visit 2');

  v_json := app.customer_live_loyalty_v384(v_biz,v_client,array['loyalty']);

  if v_json->'tier' is null or v_json->'tier' = 'null'::jsonb then
    raise exception 'v393 A1: tier key missing/null with tiers spine active and a visible ladder: %', v_json;
  end if;
  if v_json->'tier'->>'name' is distinct from 'Bronze' then
    raise exception 'v393 A2: expected current tier Bronze at metric 2 (paused Gold@2 skipped), got %', v_json->'tier'->>'name';
  end if;
  if v_json->'tier'->'next'->>'name' is distinct from 'Silver' then
    raise exception 'v393 A3: expected next tier Silver, got %', v_json->'tier'->'next'->>'name';
  end if;
  if (v_json->'tier'->'next'->>'remaining')::numeric is distinct from 1::numeric then
    raise exception 'v393 A4: expected remaining 1 to Silver, got %', v_json->'tier'->'next'->>'remaining';
  end if;
  if v_json->>'model' is distinct from 'both' then
    raise exception 'v393 A5: expected model both (points+tiers), got %', v_json->>'model';
  end if;

  -- The stamps switch, as the spine sees it.
  update public.business_programmes set active=false where business_id=v_biz and kind in ('points','tiers');
  insert into public.business_programmes(business_id,kind,active,sort) values(v_biz,'stamps',true,3)
  on conflict (business_id,kind) do update set active=true;

  v_json := app.customer_live_loyalty_v384(v_biz,v_client,array['loyalty']);
  if v_json->>'model' is distinct from 'stamps' then
    raise exception 'v393 A6: expected model stamps after switch, got %', v_json->>'model';
  end if;
  if v_json->'tier' is not null and v_json->'tier' <> 'null'::jsonb then
    raise exception 'v393 A7: tier must be null in stamps mode, got %', v_json->'tier';
  end if;

  -- Tiers back on but every rung soft-deleted: null, not an empty shell.
  update public.business_programmes set active=true where business_id=v_biz and kind='tiers';
  update public.loyalty_tiers set deleted_at=now() where business_id=v_biz;
  v_json := app.customer_live_loyalty_v384(v_biz,v_client,array['loyalty']);
  if v_json->'tier' is not null and v_json->'tier' <> 'null'::jsonb then
    raise exception 'v393 A8: tier must be null when every ladder row is deleted, got %', v_json->'tier';
  end if;

  raise notice 'v393 suite: 8 assertions passed';
end $v393$;

rollback;
