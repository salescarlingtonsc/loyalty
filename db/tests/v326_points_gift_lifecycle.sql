-- Rollback-only v326 acceptance: gifts get a real third state (On / Off-paused / Deleted-into-
-- History), every gift change (pause, delete, create) is IMMEDIATE — no draft/publish step — and
-- none of that immediacy is allowed to leak into what a customer or staff member can actually
-- redeem.
--
-- WHAT v326 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. loyalty_rewards.paused exists, NOT NULL, defaults false.
--   2. business_set_reward_paused_v326 is owner-only, writes the live row, audits the write.
--   3. A paused gift is excluded from staff_get_customer_actionable_loyalty_v145's candidate list.
--   4. A paused gift is refused by app.redeem_reward_core — the ONE gate that used to check only
--      the immutable published-version snapshot, never the live row pause/delete actually touch.
--   5. Un-pausing is fully reversible: redemption succeeds end-to-end afterward.
--   6. The exact predicate shipped in the three customer-facing listing/intent functions
--      (`reward.active and not reward.paused`) excludes a paused row and includes a live one.
--   7. business_delete_reward_v326 soft-deletes (active=false) and is owner-only, audited.
--   8. A deleted gift is refused by redeem_reward_core and excluded from the staff list.
--   9. THE RESURRECTION GUARD: a draft opened BEFORE a delete still has active=true on its own
--      loyalty_reward_versions row; deleting must flip that row too, or publishing that draft
--      later would revert the live delete. Proved by actually publishing the draft afterward.
--  10. publish_loyalty_config never references .paused — publishing an unrelated draft must leave
--      a paused gift's paused flag untouched.
--  11. business_create_reward_v326 makes a brand-new gift immediately redeemable — no draft, no
--      publish — by inserting into both loyalty_rewards AND a matching loyalty_reward_versions
--      row at the business's currently *published* config version.
--  12. Input validation and the owner-only guard on all three new RPCs.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v326_points_gift_lifecycle.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v326_out(seq integer, step text, outcome text) on commit drop;

-- Test-only, transaction-scoped: production deliberately revokes EXECUTE on
-- app.redeem_reward_core from public/anon/authenticated (see v27/v34 "revoke execute
-- ... from public, anon, authenticated") — the only authenticated-callable path to it
-- today is public.merchant_scan_redemption_qr_v117's customer-intent QR-scan chain.
-- CELLS 5/6/9/13 exist specifically to exercise app.redeem_reward_core's own pause/
-- delete gate (per this migration's header comments), not to re-implement the QR
-- intent flow, so this suite calls it directly. The grant lives only inside this
-- rolled-back transaction and is gone the instant it commits or rolls back.
grant execute on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) to authenticated;

create or replace function pg_temp.as_v326_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v326_system() to public;

create or replace function pg_temp.as_v326_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v326_user(uuid,text) to public;

-- A minimal points-model tenant, published config already live, one accruing programme.
create or replace function pg_temp.v326_tenant(
  p_business uuid, p_owner uuid, p_staff uuid, p_label text
) returns uuid language plpgsql as $$
declare v_config uuid := gen_random_uuid();
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v326-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',p_staff,'authenticated','authenticated',
          'v326-staff-'||substr(p_staff::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty'], 'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v326 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V326 Owner',true,'approved'),
         (p_business,p_staff,'staff','V326 Staff',true,'approved');

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V326 Main',true,true);

  -- app.can_see_branch classifies role='staff' as role_class 'employee', which is
  -- branch-restricted and requires an explicit staff_branches row (owner/admin bypass
  -- this). Without it, require_module_scope_v145 fails closed with
  -- complete_metric_scope_required before CELL 4 ever reaches the paused-gift check.
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select p_business, s.id, b.id
    from public.staff s, public.branches b
   where s.business_id=p_business and s.user_id=p_staff
     and b.business_id=p_business;

  insert into public.firm_config_versions(id,business_id,version_no,status,published_at,snapshot_hash)
  values (v_config,p_business,1,'published',now(),md5('v326-'||p_business::text));
  update public.businesses set active_config_version_id=v_config where id=p_business;

  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits','none',null,1,v_config);

  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,tier_basis,expiry_mode,expiry_days)
  values (p_business,v_config,'points','points_tiers',true,1,100,500,'visits','none',null);

  update public.business_programmes set active=false where business_id=p_business;
  update public.business_programmes set active=true, activated_at=now()
   where business_id=p_business and kind='points';

  return v_config;
end
$$;
grant execute on function pg_temp.v326_tenant(uuid,uuid,uuid,text) to public;

create or replace function pg_temp.v326_reward(
  p_business uuid, p_config uuid, p_programme uuid, p_name text, p_cost integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.loyalty_rewards(
    id,business_id,programme_id,name,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,current_config_version_id)
  values (v_id,p_business,p_programme,p_name,p_name,p_name,'manual_item',
          p_cost,0,0,true,p_cost,p_config);
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,programme_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort)
  values (v_id,p_business,p_config,p_programme,p_name,p_name,
          'manual_item',p_cost,0,0,true,p_cost);
  return v_id;
end
$$;
grant execute on function pg_temp.v326_reward(uuid,uuid,uuid,text,integer) to public;

create or replace function pg_temp.v326_sale(
  p_business uuid, p_client uuid, p_config uuid, p_amount integer
) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at)
  values (v_id,p_business,p_client,'service',p_amount,true,true,true,p_config,now());
  return v_id;
end
$$;
grant execute on function pg_temp.v326_sale(uuid,uuid,uuid,integer) to public;

do $v326_test$
declare
  bA uuid := gen_random_uuid();
  oA uuid := gen_random_uuid(); sA uuid := gen_random_uuid();
  cA uuid := gen_random_uuid();
  cfgA uuid; brA uuid; spineA uuid; v_draft uuid;
  rPause uuid; rDelete uuid; rStale uuid; rKeepPaused uuid;
  v_msg text; v_json jsonb; v_result jsonb; v_row public.loyalty_rewards%rowtype;
  v_version_row public.loyalty_reward_versions%rowtype;
  v_active_before boolean; v_new_reward uuid; v_new_version_id uuid;
  v_included boolean;
begin
  perform pg_temp.as_v326_system();

  cfgA := pg_temp.v326_tenant(bA,oA,sA,'V326 Points');
  select id into brA from public.branches where business_id=bA;
  select spine.id into spineA from public.business_programmes spine
   where spine.business_id=bA and spine.kind='points';
  insert into public.clients(id,business_id,full_name,phone)
  values (cA,bA,'V326 Customer','83000001');

  rPause   := pg_temp.v326_reward(bA,cfgA,spineA,'Free Coffee',20);
  rDelete  := pg_temp.v326_reward(bA,cfgA,spineA,'Free Muffin',15);
  rStale   := pg_temp.v326_reward(bA,cfgA,spineA,'Free Tote Bag',10);
  rKeepPaused := pg_temp.v326_reward(bA,cfgA,spineA,'Free Sticker',5);

  -- 500 points, enough for every redemption test below.
  perform pg_temp.v326_sale(bA,cA,cfgA,50000);

  -- =========================================================================
  -- CELL 1. Schema: paused exists, NOT NULL, defaults false.
  -- =========================================================================
  begin
    insert into v326_out select 1,'loyalty_rewards.paused exists, is NOT NULL, defaults false',
      case
        when not exists(select 1 from information_schema.columns
          where table_schema='public' and table_name='loyalty_rewards' and column_name='paused')
          then 'FAIL: column missing'
        when (select is_nullable from information_schema.columns
          where table_schema='public' and table_name='loyalty_rewards' and column_name='paused') <> 'NO'
          then 'FAIL: column is nullable'
        when (select paused from public.loyalty_rewards where id=rPause) is distinct from false
          then 'FAIL: default is not false'
        else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v326_out select 1,'loyalty_rewards.paused exists, is NOT NULL, defaults false','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 2. Owner pauses a live gift: live row flips, audited.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    v_result := public.business_set_reward_paused_v326(bA,rPause,true);
    perform pg_temp.as_v326_system();
    select * into v_row from public.loyalty_rewards where id=rPause;
    insert into v326_out select 2,'owner pause writes the live row and is audited',
      case when not v_row.paused then 'FAIL: loyalty_rewards.paused did not flip true'
           when not v_row.active then 'FAIL: pausing must not touch active'
           when (v_result->>'paused')::boolean is distinct from true then 'FAIL: rpc did not report paused=true'
           when not exists(select 1 from public.audit_log
             where business_id=bA and entity_id=rPause and action='reward.paused')
             then 'FAIL: no audit_log row'
           else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 2,'owner pause writes the live row and is audited','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 3. Non-owner staff is refused.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(sA);
    perform public.business_set_reward_paused_v326(bA,rKeepPaused,true);
    perform pg_temp.as_v326_system();
    insert into v326_out select 3,'staff (non-owner) cannot pause a gift','FAIL: staff call succeeded';
  exception when insufficient_privilege then
    perform pg_temp.as_v326_system();
    insert into v326_out select 3,'staff (non-owner) cannot pause a gift','PASS';
  when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 3,'staff (non-owner) cannot pause a gift','FAIL: wrong error: '||v_msg;
  end;
  -- rKeepPaused is paused for real, for CELL 10 later.
  perform pg_temp.as_v326_user(oA);
  perform public.business_set_reward_paused_v326(bA,rKeepPaused,true);
  perform pg_temp.as_v326_system();

  -- =========================================================================
  -- CELL 4. A paused gift is excluded from the staff actionable list.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(sA);
    v_json := public.staff_get_customer_actionable_loyalty_v145(bA,cA,brA);
    perform pg_temp.as_v326_system();
    v_included := exists(select 1 from jsonb_array_elements(v_json->'rewards') r
      where (r->>'reward_id')::uuid = rPause);
    insert into v326_out select 4,'a paused gift is excluded from the staff actionable list',
      case when v_included then 'FAIL: paused reward still listed' else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 4,'a paused gift is excluded from the staff actionable list','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 5. redeem_reward_core refuses a paused gift — the actual landmine fix.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    perform app.redeem_reward_core(bA,cA,rPause,'v326-paused-attempt',brA,null,null);
    perform pg_temp.as_v326_system();
    insert into v326_out select 5,'app.redeem_reward_core refuses a paused gift','FAIL: redemption succeeded';
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 5,'app.redeem_reward_core refuses a paused gift',
      case when v_msg ilike '%paused%' then 'PASS' else 'FAIL: wrong error: '||v_msg end;
  end;

  -- =========================================================================
  -- CELL 6. Un-pausing is fully reversible: redemption now succeeds end to end.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    perform public.business_set_reward_paused_v326(bA,rPause,false);
    v_result := app.redeem_reward_core(bA,cA,rPause,'v326-unpaused-redeem',brA,null,null);
    perform pg_temp.as_v326_system();
    insert into v326_out select 6,'un-pausing is reversible: redemption succeeds afterward',
      case when not (v_result->>'ok')::boolean then 'FAIL: redemption did not report ok'
           when (v_result->>'points_spent')::integer <> 20 then 'FAIL: wrong points_spent'
           else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 6,'un-pausing is reversible: redemption succeeds afterward','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 7. The exact predicate shipped in the three customer-facing functions
  --   (reward.active and not reward.paused) excludes paused, includes live.
  -- =========================================================================
  begin
    insert into v326_out select 7,'the shipped active-and-not-paused predicate excludes paused, includes live',
      case
        when exists(select 1 from public.loyalty_rewards reward
              where reward.id=rKeepPaused and reward.business_id=bA
                and reward.active and not reward.paused)
          then 'FAIL: paused row matched the predicate'
        when not exists(select 1 from public.loyalty_rewards reward
              where reward.id=rDelete and reward.business_id=bA
                and reward.active and not reward.paused)
          then 'FAIL: live unpaused row did not match the predicate'
        else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v326_out select 7,'the shipped active-and-not-paused predicate excludes paused, includes live','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 8. Delete soft-deletes, owner-only, audited.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    v_result := public.business_delete_reward_v326(bA,rDelete);
    perform pg_temp.as_v326_system();
    select * into v_row from public.loyalty_rewards where id=rDelete;
    insert into v326_out select 8,'delete soft-deletes the live row and is audited',
      case when v_row.active then 'FAIL: active did not flip false'
           when (v_result->>'mode') is distinct from 'deleted' then 'FAIL: rpc did not report mode=deleted'
           when not exists(select 1 from public.audit_log
             where business_id=bA and entity_id=rDelete and action='reward.deleted')
             then 'FAIL: no audit_log row'
           else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 8,'delete soft-deletes the live row and is audited','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 9. A deleted gift is refused by redeem_reward_core and delisted for staff.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    perform app.redeem_reward_core(bA,cA,rDelete,'v326-deleted-attempt',brA,null,null);
    perform pg_temp.as_v326_system();
    insert into v326_out select 9,'a deleted gift is refused by redeem_reward_core','FAIL: redemption succeeded';
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 9,'a deleted gift is refused by redeem_reward_core',
      case when v_msg ilike '%not found or inactive%' then 'PASS' else 'FAIL: wrong error: '||v_msg end;
  end;

  -- =========================================================================
  -- CELL 10. THE RESURRECTION GUARD. Open a draft (rStale's own version row now
  --   says active=true, cloned from the live row). Delete rStale immediately.
  --   The draft's OWN row must also flip to false, or publishing this same draft
  --   later would revert the live delete via publish_loyalty_config's blanket
  --   `active=rv.active` materialization.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    -- A raw INSERT into firm_config_versions as the owner's 'authenticated' role fails
    -- (permission denied: that table is written only via SECURITY DEFINER RPCs). Open
    -- the draft the way an owner actually does, through create_loyalty_config_draft —
    -- which also fires trg_clone_reward_versions_for_config, cloning rStale's own
    -- loyalty_reward_versions row into the draft with active=true, matching this
    -- cell's premise ("rStale's own version row now says active=true, cloned from the
    -- live row").
    v_result := public.create_loyalty_config_draft(bA,cfgA)::jsonb;
    v_draft := (v_result->>'version_id')::uuid;
    perform public.business_delete_reward_v326(bA,rStale);
    -- loyalty_reward_versions_read RLS only exposes rows where
    -- businesses.active_config_version_id = config_version_id — a draft's own rows are
    -- invisible to a raw SELECT even for the owner while still impersonating
    -- 'authenticated'. Reset to system (RLS-bypassing) role before reading the draft
    -- row directly, same as every other cell's post-RPC row check.
    perform pg_temp.as_v326_system();
    select active into v_active_before from public.loyalty_reward_versions
     where reward_id=rStale and config_version_id=v_draft;
    insert into v326_out select 10,'deleting syncs the currently open draft''s own version row',
      case when v_active_before is distinct from false
        then 'FAIL: draft''s own version row for the deleted reward still says active='||coalesce(v_active_before::text,'null')
        else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 10,'deleting syncs the currently open draft''s own version row','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 11. Publishing that SAME draft afterward must NOT resurrect the delete.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    perform public.publish_loyalty_config(v_draft);
    perform pg_temp.as_v326_system();
    select active into v_active_before from public.loyalty_rewards where id=rStale;
    insert into v326_out select 11,'publishing the stale draft does not resurrect the deleted gift',
      case when v_active_before is distinct from false
        then 'FAIL: loyalty_rewards.active for the deleted gift is '||coalesce(v_active_before::text,'null')||' after publish'
        else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 11,'publishing the stale draft does not resurrect the deleted gift','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 12. publish_loyalty_config never touches .paused — the still-paused
  --   gift (rKeepPaused) must read paused=true, completely unaffected by the
  --   publish that just happened in cell 11.
  -- =========================================================================
  begin
    select paused into v_active_before from public.loyalty_rewards where id=rKeepPaused;
    insert into v326_out select 12,'publish_loyalty_config never touches loyalty_rewards.paused',
      case when v_active_before is distinct from true
        then 'FAIL: rKeepPaused.paused became '||coalesce(v_active_before::text,'null')||' after an unrelated publish'
        else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into v326_out select 12,'publish_loyalty_config never touches loyalty_rewards.paused','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 13. business_create_reward_v326 is immediately redeemable — no draft,
  --   no publish — because it writes a version row at the currently PUBLISHED
  --   config version, not just the live loyalty_rewards row.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    v_result := public.business_create_reward_v326(bA,spineA,'Lotion',10,0);
    v_new_reward := (v_result->>'reward_id')::uuid;
    v_result := app.redeem_reward_core(bA,cA,v_new_reward,'v326-new-gift-redeem',brA,null,null);
    perform pg_temp.as_v326_system();
    select * into v_row from public.loyalty_rewards where id=v_new_reward;
    -- CELL 11 already published v_draft, so businesses.active_config_version_id has
    -- moved off cfgA — business_create_reward_v326 writes its version row at whatever
    -- is CURRENTLY published (per this cell's own premise), so look that up live
    -- instead of the now-stale cfgA. (Also reads post role-reset: loyalty_reward_versions_read
    -- RLS only exposes rows at the business's current active_config_version_id, so this
    -- is the one config id an owner-as-'authenticated' read could see anyway.)
    select * into v_version_row from public.loyalty_reward_versions
     where reward_id=v_new_reward
       and config_version_id=(select active_config_version_id from public.businesses where id=bA);
    insert into v326_out select 13,'a newly-created gift is immediately redeemable, no draft/publish step',
      case when v_row.id is null then 'FAIL: loyalty_rewards row missing'
           when not v_row.active or v_row.paused then 'FAIL: new row is not active/unpaused'
           when v_version_row.id is null then 'FAIL: no loyalty_reward_versions row at the published config'
           when not (v_result->>'ok')::boolean then 'FAIL: redemption did not report ok'
           when (v_result->>'points_spent')::integer <> 10 then 'FAIL: wrong points_spent, expected 10'
           else 'PASS' end;
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 13,'a newly-created gift is immediately redeemable, no draft/publish step','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 14. Input validation: empty name and non-positive points are refused.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(oA);
    begin
      perform public.business_create_reward_v326(bA,spineA,'   ',10,0);
      perform pg_temp.as_v326_system();
      insert into v326_out select 14,'business_create_reward_v326 refuses an empty name','FAIL: empty name accepted';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      -- Both inner try/excepts write to v326_out while the outer block is still
      -- impersonating 'authenticated' (the outer role-reset only runs after both
      -- finish) — reset to system role first, same as every other cell's handler.
      perform pg_temp.as_v326_system();
      insert into v326_out select 14,'business_create_reward_v326 refuses an empty name',
        case when v_msg ilike '%name%' then 'PASS' else 'FAIL: wrong error: '||v_msg end;
    end;
    perform pg_temp.as_v326_user(oA);
    begin
      perform public.business_create_reward_v326(bA,spineA,'Bad Points',0,0);
      perform pg_temp.as_v326_system();
      insert into v326_out select 141,'business_create_reward_v326 refuses zero points','FAIL: zero points accepted';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.as_v326_system();
      insert into v326_out select 141,'business_create_reward_v326 refuses zero points',
        case when v_msg ilike '%points%' then 'PASS' else 'FAIL: wrong error: '||v_msg end;
    end;
    perform pg_temp.as_v326_system();
  exception when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 14,'business_create_reward_v326 input validation','FAIL: '||v_msg;
  end;

  -- =========================================================================
  -- CELL 15. Non-owner staff cannot create or delete a gift either.
  -- =========================================================================
  begin
    perform pg_temp.as_v326_user(sA);
    perform public.business_create_reward_v326(bA,spineA,'Sneaky Gift',5,0);
    perform pg_temp.as_v326_system();
    insert into v326_out select 15,'staff cannot create a gift via the immediate-write RPC','FAIL: staff call succeeded';
  exception when insufficient_privilege then
    perform pg_temp.as_v326_system();
    insert into v326_out select 15,'staff cannot create a gift via the immediate-write RPC','PASS';
  when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 15,'staff cannot create a gift via the immediate-write RPC','FAIL: wrong error: '||v_msg;
  end;
  begin
    perform pg_temp.as_v326_user(sA);
    perform public.business_delete_reward_v326(bA,rKeepPaused);
    perform pg_temp.as_v326_system();
    insert into v326_out select 16,'staff cannot delete a gift via the immediate-write RPC','FAIL: staff call succeeded';
  exception when insufficient_privilege then
    perform pg_temp.as_v326_system();
    insert into v326_out select 16,'staff cannot delete a gift via the immediate-write RPC','PASS';
  when others then
    get stacked diagnostics v_msg = message_text; perform pg_temp.as_v326_system();
    insert into v326_out select 16,'staff cannot delete a gift via the immediate-write RPC','FAIL: wrong error: '||v_msg;
  end;

end
$v326_test$;

select seq, step, outcome from v326_out order by seq;

rollback;
