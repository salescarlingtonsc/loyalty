-- Rollback-only v331 acceptance: Tiered membership gets a full parallel immediate-write layer.
--
-- WHAT v331 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. loyalty_tiers.paused/deleted_at exist, default false/null.
--   2. business_create_tier_v331 creates a live tier AND mirrors it into loyalty_tier_versions
--      at the business's currently published config version (owner-only).
--   3. business_set_tier_paused_v331 pauses/unpauses (owner-only, idempotent).
--   4. business_delete_tier_v331 soft-deletes, refuses when it would leave a live tier programme
--      with zero active tiers, and is owner-only.
--   5. THE CORRECTNESS GATE: app.loyalty_tier_for, customer_get_effective_tier_v143 (current/
--      next/ladder), v176_reward_gate_threshold and customer_portal_capabilities all exclude a
--      paused or deleted tier from live customer-facing computation.
--   6. THE RESURRECTION GUARD (the hard part): publishing an UNRELATED draft must not revert a
--      v331 pause/delete on an existing (wizard-created) tier, and must not destroy a
--      brand-new v331-created tier that no draft ever knew about.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v331_tier_lifecycle.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v331_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v331_out to public;

create or replace function pg_temp.as_v331_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v331_system() to public;

create or replace function pg_temp.as_v331_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v331_user(uuid,text) to public;

-- A minimal points_tiers tenant: approved workspace, unpaused subscription, published config
-- (tier_basis='visits'), one owner, tiers spine row active, two wizard-created tiers already
-- live (Silver/Gold), one client with 5 completed visits (so Silver, threshold 3, is their
-- current tier and Gold, threshold 10, is next).
create or replace function pg_temp.v331_tenant(
  p_business uuid, p_owner uuid, p_client uuid, p_config uuid, p_tier_silver uuid, p_tier_gold uuid, p_label text,
  p_customer_auth uuid default null
) returns void language plpgsql as $$
declare
  v_link uuid := gen_random_uuid();
  v_identity uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v331-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;
  if p_customer_auth is not null then
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',p_customer_auth,'authenticated','authenticated',
            'v331-customer-'||substr(p_customer_auth::text,1,8)||'@example.test','',now(),now(),now())
    on conflict (id) do nothing;
  end if;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'tiers');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v331 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V331 Owner',true,'approved');

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V331 Main',true,true);

  insert into public.clients(id,business_id,full_name)
  values (p_client,p_business,'V331 Client');

  if p_customer_auth is not null then
    insert into public.customer_identities(auth_user_id,status,created_via)
    values (p_customer_auth,'active','phone_registration')
    returning id into v_identity;
    perform set_config('app.customer_link_insert_id',v_link::text,true);
    insert into public.customer_links(
      id,business_id,identity_id,auth_user_id,client_id,state,
      verification_method,verified_at)
    values (v_link,p_business,v_identity,p_customer_auth,p_client,'verified',
      'firm_invitation',now());
    perform set_config('app.customer_link_insert_id','',true);
  end if;

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at,snapshot_hash)
  values (p_config,p_business,1,'published',now(),md5('v331-'||p_business::text));
  update public.businesses set active_config_version_id=p_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits','none',null,1,p_config);

  -- publish_loyalty_config reads its typed snapshot from loyalty_program_versions, not
  -- loyalty_programs -- a draft cloned/published later needs a real row here to find.
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,tier_basis,expiry_mode,expiry_days)
  values (p_business,p_config,'points','points_tiers',true,1,100,500,'visits','none',null);

  update public.business_programmes set active=false where business_id=p_business;
  update public.business_programmes set active=true, activated_at=now()
   where business_id=p_business and kind='tiers';

  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values (p_tier_silver,p_business,'Silver',3,1,1),
         (p_tier_gold,p_business,'Gold',10,2,2);
  insert into public.loyalty_tier_versions(tier_id,business_id,config_version_id,name,threshold,points_multiplier,sort,active)
  values (p_tier_silver,p_business,p_config,'Silver',3,1,1,true),
         (p_tier_gold,p_business,p_config,'Gold',10,2,2,true);

  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  select gen_random_uuid(),p_business,p_client,'service',1000,true,true,true,p_config,now()
  from generate_series(1,5);
end
$$;
grant execute on function pg_temp.v331_tenant(uuid,uuid,uuid,uuid,uuid,uuid,text,uuid) to public;

do $v331_test$
declare
  bA uuid := gen_random_uuid(); oA uuid := gen_random_uuid(); cA uuid := gen_random_uuid();
  cAauth uuid := gen_random_uuid();
  cfgA uuid := gen_random_uuid(); tSilver uuid := gen_random_uuid(); tGold uuid := gen_random_uuid();
  v_result jsonb; v_row public.loyalty_tiers%rowtype; v_tier record; v_slug text;
  v_new_tier uuid; v_new_draft uuid; v_draft2 uuid := gen_random_uuid(); v_draft3 uuid := gen_random_uuid();
  v_gate integer;
  v_msg text;
begin
  perform pg_temp.as_v331_system();
  perform pg_temp.v331_tenant(bA, oA, cA, cfgA, tSilver, tGold, 'V331 Alpha', cAauth);
  select slug into v_slug from public.businesses where id=bA;

  -- CELL 1: columns exist, default correctly.
  begin
    select * into v_row from public.loyalty_tiers where id=tSilver;
    if v_row.paused=false and v_row.deleted_at is null then
      insert into v331_out values (1,'paused/deleted_at exist and default correctly','PASS');
    else
      insert into v331_out values (1,'paused/deleted_at exist and default correctly',
        format('FAIL - paused=%s deleted_at=%s',v_row.paused,v_row.deleted_at));
    end if;
  end;

  -- CELL 2: baseline -- before any v331 write, the client (5 visits) is Silver, Gold is next.
  perform pg_temp.as_v331_user(cAauth);
  select public.customer_get_effective_tier_v143(bA) into v_result;
  perform pg_temp.as_v331_system();
  if (v_result->'tier'->'current'->>'label')='Silver' and (v_result->'tier'->'next'->>'label')='Gold' then
    insert into v331_out values (2,'baseline: 5-visit client is Silver, Gold is next','PASS');
  else
    insert into v331_out values (2,'baseline: 5-visit client is Silver, Gold is next','FAIL - '||v_result::text);
  end if;

  -- CELL 3: pausing Silver removes it from ranking -- the client falls to no-tier (Gold is
  -- still next, unattained).
  perform pg_temp.as_v331_user(oA);
  select public.business_set_tier_paused_v331(bA, tSilver, true) into v_result;
  if (v_result->>'status')='ok' and (v_result->>'paused')='true' then
    insert into v331_out values (3,'owner pauses Silver','PASS');
  else
    insert into v331_out values (3,'owner pauses Silver','FAIL - '||v_result::text);
  end if;

  perform pg_temp.as_v331_user(cAauth);
  select public.customer_get_effective_tier_v143(bA) into v_result;
  -- NOTE: jsonb_build_object('current', case ... else null end, ...) stores an explicit JSON
  -- null when there's no current tier -- that's the correct, idiomatic API shape (a frontend's
  -- `result.tier.current === null` reads exactly right). But `x->'current'` then yields a jsonb
  -- value whose typeof is 'null', which is NOT SQL NULL, so `(...) is null` is always false here.
  -- Use `->>'id'` (text extraction), which correctly folds JSON null to SQL NULL, same as every
  -- other cell in this file already does for 'label'/'id' checks.
  if (v_result->'tier'->'current'->>'id') is null and (v_result->'tier'->'next'->>'label')='Gold' then
    insert into v331_out values (4,'CORRECTNESS GATE: paused Silver excluded from customer_get_effective_tier_v143','PASS');
  else
    insert into v331_out values (4,'CORRECTNESS GATE: paused Silver excluded from customer_get_effective_tier_v143','FAIL - '||v_result::text);
  end if;

  perform pg_temp.as_v331_system();
  select * into v_tier from app.loyalty_tier_for(bA, cA);
  if v_tier.id is null then
    insert into v331_out values (5,'CORRECTNESS GATE: app.loyalty_tier_for also excludes paused Silver','PASS');
  else
    insert into v331_out values (5,'CORRECTNESS GATE: app.loyalty_tier_for also excludes paused Silver',
      format('FAIL - resolved tier %s',v_tier.name));
  end if;

  -- CELL 6: unpausing restores it.
  perform pg_temp.as_v331_user(oA);
  select public.business_set_tier_paused_v331(bA, tSilver, false) into v_result;
  perform pg_temp.as_v331_user(cAauth);
  select public.customer_get_effective_tier_v143(bA) into v_result;
  if (v_result->'tier'->'current'->>'label')='Silver' then
    insert into v331_out values (6,'unpausing Silver restores it','PASS');
  else
    insert into v331_out values (6,'unpausing Silver restores it','FAIL - '||v_result::text);
  end if;

  -- CELL 7: v176_reward_gate_threshold falls back to the frozen snapshot once a tier is deleted,
  -- and returns the LIVE threshold while the tier is merely paused (own invariant: "pausing a
  -- tier must not open a gate" -- but the live number should still be authoritative until gone).
  perform pg_temp.as_v331_system();
  begin
    perform pg_temp.as_v331_user(oA);
    perform public.business_set_tier_paused_v331(bA, tGold, true);
    perform pg_temp.as_v331_system();
    select app.v176_reward_gate_threshold(bA, tGold, 999) into v_gate;
    if v_gate=999 then
      insert into v331_out values (7,'CORRECTNESS GATE: reward gate falls back to frozen threshold once tier is paused','PASS');
    else
      insert into v331_out values (7,'CORRECTNESS GATE: reward gate falls back to frozen threshold once tier is paused',
        format('FAIL - live=%s',v_gate));
    end if;
    perform pg_temp.as_v331_user(oA);
    perform public.business_set_tier_paused_v331(bA, tGold, false);
    perform pg_temp.as_v331_system();
  end;

  -- CELL 8: deleting the ONLY remaining tier on a live tiers programme is refused.
  perform pg_temp.as_v331_user(oA);
  begin
    perform public.business_delete_tier_v331(bA, tSilver);
    perform public.business_delete_tier_v331(bA, tGold);
    insert into v331_out values (8,'deleting down to zero tiers on a live programme is refused','FAIL - no exception raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like '%at least one tier%' then
      insert into v331_out values (8,'deleting down to zero tiers on a live programme is refused','PASS');
    else
      insert into v331_out values (8,'deleting down to zero tiers on a live programme is refused','FAIL - wrong message: '||v_msg);
    end if;
  end;
  perform pg_temp.as_v331_system();
  select * into v_row from public.loyalty_tiers where id=tSilver;
  if v_row.deleted_at is null then
    insert into v331_out values (9,'refused delete left Silver untouched','PASS');
  else
    insert into v331_out values (9,'refused delete left Silver untouched','FAIL - row was mutated');
  end if;

  -- CELL 10: deleting Gold (Silver stays) succeeds -- Silver alone keeps the programme non-empty.
  perform pg_temp.as_v331_user(oA);
  select public.business_delete_tier_v331(bA, tGold) into v_result;
  if (v_result->>'status')='ok' and (v_result->>'mode')='deleted' then
    insert into v331_out values (10,'deleting Gold while Silver remains succeeds','PASS');
  else
    insert into v331_out values (10,'deleting Gold while Silver remains succeeds','FAIL - '||v_result::text);
  end if;
  perform pg_temp.as_v331_system();
  select * into v_row from public.loyalty_tiers where id=tGold;
  if v_row.paused=true and v_row.deleted_at is not null then
    insert into v331_out values (11,'deleted Gold row: paused=true AND deleted_at set','PASS');
  else
    insert into v331_out values (11,'deleted Gold row: paused=true AND deleted_at set',
      format('FAIL - paused=%s deleted_at=%s',v_row.paused,v_row.deleted_at));
  end if;

  -- CELL 12: CORRECTNESS GATE -- customer_portal_capabilities' tiers flag goes false once every
  -- tier is paused (Silver is the only one left; pause it too).
  perform pg_temp.as_v331_user(oA);
  perform public.business_set_tier_paused_v331(bA, tSilver, true);
  perform pg_temp.as_v331_user(cAauth);
  select public.customer_portal_capabilities(v_slug) into v_result;
  if (v_result->>'tiers')='false' then
    insert into v331_out values (12,'CORRECTNESS GATE: customer_portal_capabilities.tiers is false when every tier is paused','PASS');
  else
    insert into v331_out values (12,'CORRECTNESS GATE: customer_portal_capabilities.tiers is false when every tier is paused','FAIL - '||v_result::text);
  end if;
  perform pg_temp.as_v331_user(oA);
  perform public.business_set_tier_paused_v331(bA, tSilver, false);

  -- CELL 13: THE RESURRECTION GUARD, part 1 -- pause Gold-replacement... actually re-pause
  -- Silver is already unpaused; pause it again, then publish an UNRELATED draft (one that never
  -- touched tiers), and confirm the pause survives publish_loyalty_config's delete+reinsert.
  perform public.business_set_tier_paused_v331(bA, tSilver, true);
  -- Use the REAL create_loyalty_config_draft RPC instead of raw INSERTs: 'authenticated' only
  -- ever holds SELECT on firm_config_versions/loyalty_program_versions/loyalty_tier_versions --
  -- every write to those tables (even impersonating the owner) has to go through a SECURITY
  -- DEFINER RPC, the same one the real draft-creation UI calls. Base explicitly on cfgA (the
  -- ORIGINAL published snapshot, pre-pause) so this draft clones tier_versions with no idea
  -- Silver was ever paused -- exactly the "stale draft" scenario this cell is testing.
  select public.create_loyalty_config_draft(bA, cfgA, 'v331_test') into v_result;
  v_draft2 := (v_result->>'version_id')::uuid;
  select public.publish_loyalty_config(v_draft2) into v_result;
  if (v_result->>'status')='published' then
    insert into v331_out values (13,'unrelated draft (predates the pause) publishes cleanly','PASS');
  else
    insert into v331_out values (13,'unrelated draft (predates the pause) publishes cleanly','FAIL - '||v_result::text);
  end if;
  perform pg_temp.as_v331_system();
  select * into v_row from public.loyalty_tiers where id=tSilver;
  if v_row.paused=true then
    insert into v331_out values (14,'RESURRECTION GUARD: Silver''s pause SURVIVES an unrelated publish','PASS');
  else
    insert into v331_out values (14,'RESURRECTION GUARD: Silver''s pause SURVIVES an unrelated publish',
      format('FAIL - paused=%s (publish_loyalty_config reverted it)',v_row.paused));
  end if;
  select * into v_row from public.loyalty_tiers where id=tGold;
  if v_row.deleted_at is not null then
    insert into v331_out values (15,'RESURRECTION GUARD: Gold''s delete also SURVIVES the same unrelated publish','PASS');
  else
    insert into v331_out values (15,'RESURRECTION GUARD: Gold''s delete also SURVIVES the same unrelated publish',
      format('FAIL - deleted_at=%s (publish_loyalty_config resurrected it)',v_row.deleted_at));
  end if;

  -- CELL 16: THE RESURRECTION GUARD, part 2 -- a BRAND NEW v331-created tier (Platinum) that no
  -- draft has ever heard of must also survive a publish of yet another fresh draft.
  perform pg_temp.as_v331_user(oA);
  select public.business_create_tier_v331(bA, 'Platinum', 20, 3) into v_result;
  v_new_tier := (v_result->>'tier_id')::uuid;
  if (v_result->>'status')='ok' then
    insert into v331_out values (16,'business_create_tier_v331 creates Platinum','PASS');
  else
    insert into v331_out values (16,'business_create_tier_v331 creates Platinum','FAIL - '||v_result::text);
  end if;
  perform pg_temp.as_v331_system();
  if exists(select 1 from public.loyalty_tier_versions where tier_id=v_new_tier and config_version_id=v_draft2) then
    insert into v331_out values (17,'create mirrors into the currently PUBLISHED version''s tier_versions','PASS');
  else
    insert into v331_out values (17,'create mirrors into the currently PUBLISHED version''s tier_versions','FAIL - no mirror row found');
  end if;

  perform pg_temp.as_v331_user(oA);
  -- Same fix as CELL 13: use the real RPC. Cloned from the NOW-published v_draft2, which (per
  -- CELL 17) already carries Platinum.
  select public.create_loyalty_config_draft(bA, v_draft2, 'v331_test') into v_result;
  v_draft3 := (v_result->>'version_id')::uuid;
  select public.publish_loyalty_config(v_draft3) into v_result;
  perform pg_temp.as_v331_system();
  select * into v_row from public.loyalty_tiers where id=v_new_tier;
  if v_row.id is not null and v_row.name='Platinum' then
    insert into v331_out values (18,'RESURRECTION GUARD: brand-new Platinum SURVIVES a later publish of a fresh draft','PASS');
  else
    insert into v331_out values (18,'RESURRECTION GUARD: brand-new Platinum SURVIVES a later publish of a fresh draft','FAIL - tier is gone');
  end if;

  -- CELL 19: a non-owner is refused, and a cross-tenant id is refused, without mutating anything.
  declare bB uuid := gen_random_uuid(); oB uuid := gen_random_uuid(); cB uuid := gen_random_uuid();
    cfgB uuid := gen_random_uuid(); tB1 uuid := gen_random_uuid(); tB2 uuid := gen_random_uuid();
    v_stranger uuid := gen_random_uuid();
  begin
    perform pg_temp.v331_tenant(bB, oB, cB, cfgB, tB1, tB2, 'V331 Beta');
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',v_stranger,'authenticated','authenticated',
            'v331-stranger@example.test','',now(),now(),now()) on conflict (id) do nothing;
    perform pg_temp.as_v331_user(v_stranger);
    begin
      perform public.business_set_tier_paused_v331(bA, tSilver, true);
      insert into v331_out values (19,'non-staff actor is refused','FAIL - no exception raised');
    exception when others then
      insert into v331_out values (19,'non-staff actor is refused','PASS');
    end;
    perform pg_temp.as_v331_user(oA);
    begin
      perform public.business_delete_tier_v331(bA, tB1);
      insert into v331_out values (20,'cross-tenant delete is refused','FAIL - no exception raised');
    exception when others then
      insert into v331_out values (20,'cross-tenant delete is refused','PASS');
    end;
  end;
end
$v331_test$;

select seq, step, outcome from v331_out order by seq;

rollback;
