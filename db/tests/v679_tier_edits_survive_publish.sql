-- Rollback-only nestly_v679 acceptance: a tier edit survives the next unrelated publish.
--
-- WHAT THE BUG WAS (audit finding F087). Manage Tiers writes public.loyalty_tiers immediately
-- (business_update_tier_v331, business_set_tier_benefits_v365, business_delete_tier_v331) and
-- never wrote public.loyalty_tier_versions. Both draft creators cloned their tier rows out of
-- the base version's SNAPSHOT, so the next unrelated loyalty save — a birthday gift, a
-- bring-back, a reward, a wizard step — opened a draft carrying pre-edit tiers and
-- publish_loyalty_config's `on conflict (id) do update set name=..., threshold=...` wrote the
-- stale values straight back over the owner's edit. Success toast, no warning, and customers
-- re-bucketed at the old thresholds and multipliers.
--
-- WHAT THIS SUITE PROVES:
--   1. Baseline: a 5-visit client is Silver, Gold is next.
--   2. The owner renames and re-thresholds Silver, gives Gold a structured benefit (which
--      re-derives its perk wording), and deletes Bronze — all through the real RPCs.
--   3. THE GATE: saving a BIRTHDAY programme (business_save_birthday_program_v424, the caller
--      proven to have reverted a real tenant) leaves every one of those edits standing.
--   4. The deleted tier is still deleted afterwards, its row was not destroyed, and Gold's
--      tier_benefits_v365 rows survived (the nestly_v577 invariant).
--   5. The CUSTOMER reader agrees: customer_get_effective_tier_v143 shows the new name.
--   6. The freshly published snapshot now matches the live ladder — the clone came from live.
--   7. Guard 2: an edit made while a draft is ALREADY OPEN reaches that draft, so publishing it
--      does not revert the edit either.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v679_tier_edits_survive_publish.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v679_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v679_out to public;

create or replace function pg_temp.as_v679_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v679_system() to public;

create or replace function pg_temp.as_v679_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v679_user(uuid,text) to public;

-- A minimal points_tiers tenant: approved workspace, unpaused subscription, published config
-- version 1 (tier_basis='visits'), one owner, the tiers spine active, three live tiers already
-- captured in that published version, and one linked client with 5 completed visits.
create or replace function pg_temp.v679_tenant(
  p_business uuid, p_owner uuid, p_client uuid, p_customer_auth uuid, p_config uuid,
  p_bronze uuid, p_silver uuid, p_gold uuid
) returns void language plpgsql as $$
declare
  v_link uuid := gen_random_uuid();
  v_identity uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v679-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_customer_auth,'authenticated','authenticated',
          'v679-customer-'||substr(p_customer_auth::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business,'V679 Tiers','v679-tiers-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'tiers');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v679 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V679 Owner',true,'approved');
  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V679 Main',true,true);
  insert into public.clients(id,business_id,full_name)
  values (p_client,p_business,'V679 Client');

  insert into public.customer_identities(auth_user_id,status,created_via)
  values (p_customer_auth,'active','phone_registration')
  returning id into v_identity;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,p_business,v_identity,p_customer_auth,p_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at,snapshot_hash)
  values (p_config,p_business,1,'published',now(),md5('v679-'||p_business::text));
  update public.businesses set active_config_version_id=p_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits','none',null,1,p_config);
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,tier_basis,expiry_mode,expiry_days)
  values (p_business,p_config,'points','points_tiers',true,1,100,500,'visits','none',null);

  update public.business_programmes set active=false where business_id=p_business;
  update public.business_programmes set active=true, activated_at=now()
   where business_id=p_business and kind='tiers';

  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,sort)
  values (p_bronze,p_business,'Bronze',1,1,1),
         (p_silver,p_business,'Silver',3,1,2),
         (p_gold,  p_business,'Gold', 10,2,3);
  insert into public.loyalty_tier_versions(
    tier_id,business_id,config_version_id,name,threshold,points_multiplier,sort,active)
  values (p_bronze,p_business,p_config,'Bronze',1,1,1,true),
         (p_silver,p_business,p_config,'Silver',3,1,2,true),
         (p_gold,  p_business,p_config,'Gold', 10,2,3,true);

  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  select gen_random_uuid(),p_business,p_client,'service',1000,true,true,true,p_config,now()
  from generate_series(1,5);
end
$$;
grant execute on function pg_temp.v679_tenant(uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid) to public;

do $v679_test$
declare
  bA uuid := gen_random_uuid(); oA uuid := gen_random_uuid();
  cA uuid := gen_random_uuid(); cAuth uuid := gen_random_uuid();
  cfg uuid := gen_random_uuid();
  tBronze uuid := gen_random_uuid();
  tSilver uuid := gen_random_uuid();
  tGold   uuid := gen_random_uuid();
  v_res jsonb; v_row public.loyalty_tiers%rowtype;
  v_published uuid; v_draft uuid; v_gold_perk text; v_n integer;
begin
  perform pg_temp.as_v679_system();
  -- This suite is one wrapping transaction (rollback-only), unlike production where each RPC
  -- call is its own transaction. app.acquire_loyalty_exclusive_v480 refuses to upgrade a
  -- transaction from a shared loyalty fence to exclusive (self-deadlock avoidance) — and the
  -- fixture's own baseline sales below acquire that shared fence via app.on_sale_recorded's
  -- v480 trigger. Take the exclusive fence up front, before anything shared-fenced runs, so the
  -- whole suite holds it for the transaction's lifetime exactly as if publish_loyalty_config had
  -- gone first in its own transaction; no assertion below depends on lock mode.
  perform app.acquire_loyalty_exclusive_v480(bA);
  perform pg_temp.v679_tenant(bA,oA,cA,cAuth,cfg,tBronze,tSilver,tGold);

  -- ------------------------------------------------------------------ 1. baseline
  perform pg_temp.as_v679_user(cAuth);
  select public.customer_get_effective_tier_v143(bA) into v_res;
  perform pg_temp.as_v679_system();
  if (v_res->'tier'->'current'->>'label')='Silver' and (v_res->'tier'->'next'->>'label')='Gold' then
    insert into v679_out values (1,'baseline: 5-visit client is Silver, Gold is next','PASS');
  else
    insert into v679_out values (1,'baseline: 5-visit client is Silver, Gold is next','FAIL - '||v_res::text);
  end if;

  -- ------------------------------------------------------------------ 2. the owner's edits
  perform pg_temp.as_v679_user(oA);

  -- rename + re-threshold + re-multiply Silver through the real Manage Tiers RPC
  select public.business_update_tier_v331(bA,tSilver,'Elite Silver',4,'Members-only hour',1.75) into v_res;
  perform pg_temp.as_v679_system();
  select * into v_row from public.loyalty_tiers where id=tSilver;
  if v_row.name='Elite Silver' and v_row.threshold=4 and v_row.points_multiplier=1.75 then
    insert into v679_out values (2,'owner renames + re-thresholds Silver (live row written)','PASS');
  else
    insert into v679_out values (2,'owner renames + re-thresholds Silver (live row written)',
      format('FAIL - name=%s threshold=%s multiplier=%s',v_row.name,v_row.threshold,v_row.points_multiplier));
  end if;

  -- a structured benefit on Gold, which re-derives its perk wording live-only
  perform pg_temp.as_v679_user(oA);
  select public.business_set_tier_benefits_v365(bA,tGold,
    jsonb_build_array(jsonb_build_object(
      'benefit_kind','custom','label','Free birthday cake','limit_count',1,'limit_period','year'))) into v_res;
  perform pg_temp.as_v679_system();
  select perk_note into v_gold_perk from public.loyalty_tiers where id=tGold;
  if v_gold_perk is not null and v_gold_perk like '%birthday cake%' then
    insert into v679_out values (3,'owner sets a Gold benefit; perk wording derived onto the live row','PASS');
  else
    insert into v679_out values (3,'owner sets a Gold benefit; perk wording derived onto the live row',
      'FAIL - perk_note='||coalesce(v_gold_perk,'<null>'));
  end if;

  -- and deletes Bronze
  perform pg_temp.as_v679_user(oA);
  select public.business_delete_tier_v331(bA,tBronze) into v_res;
  perform pg_temp.as_v679_system();
  select * into v_row from public.loyalty_tiers where id=tBronze;
  if v_row.deleted_at is not null and v_row.paused then
    insert into v679_out values (4,'owner deletes Bronze (soft-deleted live)','PASS');
  else
    insert into v679_out values (4,'owner deletes Bronze (soft-deleted live)','FAIL - '||coalesce(v_res::text,'<null>'));
  end if;

  -- ------------------------------------------------------------------ 3. the unrelated publish
  perform pg_temp.as_v679_user(oA);
  select public.business_save_birthday_program_v424(bA, jsonb_build_object(
    'active',true,
    'customer_label','Birthday treat',
    'customer_description','Ten percent off in your birthday week.',
    'customer_terms','One per customer per year.',
    'fulfillment_kind','discount_pct',
    'discount_percent',10,
    'window_days_before',7,
    'window_days_after',7,
    'window_mode','days',
    'sort',0), 'v679-birthday-'||substr(bA::text,1,8)) into v_res;
  perform pg_temp.as_v679_system();
  if (v_res->>'status')='published' then
    insert into v679_out values (5,'an UNRELATED birthday save opens a draft and publishes it','PASS');
  else
    insert into v679_out values (5,'an UNRELATED birthday save opens a draft and publishes it',
      'FAIL - '||coalesce(v_res::text,'<null>'));
  end if;

  -- ------------------------------------------------------------------ 4. THE GATE
  select * into v_row from public.loyalty_tiers where id=tSilver;
  if v_row.name='Elite Silver' and v_row.threshold=4 and v_row.points_multiplier=1.75
     and v_row.perk_note='Members-only hour' then
    insert into v679_out values (6,'THE GATE: the Silver edit still stands after the publish','PASS');
  else
    insert into v679_out values (6,'THE GATE: the Silver edit still stands after the publish',
      format('FAIL - reverted to name=%s threshold=%s multiplier=%s perk=%s',
             v_row.name,v_row.threshold,v_row.points_multiplier,coalesce(v_row.perk_note,'<null>')));
  end if;

  select * into v_row from public.loyalty_tiers where id=tGold;
  if v_row.perk_note is not distinct from v_gold_perk then
    insert into v679_out values (7,'THE GATE: the Gold benefit wording still stands after the publish','PASS');
  else
    insert into v679_out values (7,'THE GATE: the Gold benefit wording still stands after the publish',
      'FAIL - perk_note='||coalesce(v_row.perk_note,'<null>'));
  end if;

  select count(*) into v_n from public.tier_benefits_v365
   where business_id=bA and tier_id=tGold and deleted_at is null and active;
  if v_n=1 then
    insert into v679_out values (8,'nestly_v577 invariant: the tier benefit row survived the publish','PASS');
  else
    insert into v679_out values (8,'nestly_v577 invariant: the tier benefit row survived the publish',
      format('FAIL - %s live benefit rows',v_n));
  end if;

  select * into v_row from public.loyalty_tiers where id=tBronze;
  if found and v_row.deleted_at is not null then
    insert into v679_out values (9,'the deleted tier is still deleted, and its row was not destroyed','PASS');
  elsif not found then
    insert into v679_out values (9,'the deleted tier is still deleted, and its row was not destroyed',
      'FAIL - the row was hard-deleted by the publish');
  else
    insert into v679_out values (9,'the deleted tier is still deleted, and its row was not destroyed',
      'FAIL - deleted_at was cleared');
  end if;

  -- ------------------------------------------------------------------ 5. the customer agrees
  perform pg_temp.as_v679_user(cAuth);
  select public.customer_get_effective_tier_v143(bA) into v_res;
  perform pg_temp.as_v679_system();
  if (v_res->'tier'->'current'->>'label')='Elite Silver' then
    insert into v679_out values (10,'the customer reader shows the edited tier, not the stale one','PASS');
  else
    insert into v679_out values (10,'the customer reader shows the edited tier, not the stale one',
      'FAIL - '||v_res::text);
  end if;

  -- ------------------------------------------------------------------ 6. the new snapshot follows live
  select active_config_version_id into v_published from public.businesses where id=bA;
  if v_published is distinct from cfg then
    select count(*) into v_n
      from public.loyalty_tier_versions v
      join public.loyalty_tiers t on t.id=v.tier_id and t.business_id=v.business_id
     where v.config_version_id=v_published and v.business_id=bA
       and (v.name is distinct from t.name
         or v.threshold is distinct from t.threshold
         or v.points_multiplier is distinct from t.points_multiplier
         or v.perk_note is distinct from t.perk_note);
    if v_n=0 then
      insert into v679_out values (11,'the newly published snapshot matches the live ladder','PASS');
    else
      insert into v679_out values (11,'the newly published snapshot matches the live ladder',
        format('FAIL - %s tier row(s) diverge',v_n));
    end if;
  else
    insert into v679_out values (11,'the newly published snapshot matches the live ladder',
      'FAIL - the birthday save did not advance the active version');
  end if;

  -- ------------------------------------------------------------------ 7. guard 2: an ALREADY-OPEN draft
  perform pg_temp.as_v679_user(oA);
  select (public.create_grow_config_draft_v138(bA,null,'grow_shared_edit')->>'version_id')::uuid into v_draft;
  -- the edit happens AFTER the draft was cloned
  perform public.business_update_tier_v331(bA,tGold,'Gold Plus',12,'Priority booking',2.5);
  perform public.publish_loyalty_config(v_draft);
  perform pg_temp.as_v679_system();
  select * into v_row from public.loyalty_tiers where id=tGold;
  if v_row.name='Gold Plus' and v_row.threshold=12 and v_row.points_multiplier=2.5 then
    insert into v679_out values (12,'GUARD 2: an edit made while a draft was open survives that draft''s publish','PASS');
  else
    insert into v679_out values (12,'GUARD 2: an edit made while a draft was open survives that draft''s publish',
      format('FAIL - reverted to name=%s threshold=%s multiplier=%s',
             v_row.name,v_row.threshold,v_row.points_multiplier));
  end if;

  -- and the Silver edit is still there two publishes later
  select * into v_row from public.loyalty_tiers where id=tSilver;
  if v_row.name='Elite Silver' and v_row.threshold=4 then
    insert into v679_out values (13,'the first edit is still standing two publishes later','PASS');
  else
    insert into v679_out values (13,'the first edit is still standing two publishes later',
      format('FAIL - name=%s threshold=%s',v_row.name,v_row.threshold));
  end if;
end
$v679_test$;

select seq, step, outcome from v679_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v679_gate$
declare
  v_bad integer;
begin
  select count(*) into v_bad from v679_out where outcome not like 'PASS%';
  if v_bad > 0 then
    raise exception 'SUITE FAILED: % assertion(s) — %', v_bad,
      (select string_agg(step, ', ') from v679_out where outcome not like 'PASS%');
  end if;
end
$v679_gate$;

rollback;
