-- Rollback-only v332 acceptance: Lifestyle bring-back rules get a real delete -> History state.
--
-- WHAT v332 CLAIMS, AND THEREFORE WHAT THIS SUITE MUST PROVE:
--   1. retention_programs.deleted_at exists, nullable, defaults null.
--   2. business_delete_retention_program_v332 is owner-gated (app.is_salon_owner, the same gate
--      public.save_retention_program_draft already uses), sets active=false AND deleted_at=now().
--   3. THE CORRECTNESS GATE, PART 1: once deleted, app.on_sale_recorded stops granting NEW
--      reward_grants (and the credit_ledger row that comes with a credit-fulfillment grant) for
--      that program immediately -- even though the currently-published retention_program_versions
--      snapshot row is immutable and still says active=true underneath.
--   4. Deleting never touches a reward_grants/credit_ledger row that was already posted before the
--      delete -- a deleted rule must never rewrite history.
--   5. THE RESURRECTION GUARD (the hard part, and materially different from v331's tier case -- see
--      the migration header): an already-open draft's own retention_program_versions row is forced
--      back to active=false by the delete; publish_loyalty_config is independently, durably patched
--      so that even if a draft's row is somehow still active=true at publish time, the live program
--      stays dead; and a BRAND NEW draft opened after the delete never even clones a row for it.
--   6. THE CORRECTNESS GATE, PART 2: app.c45_base_actionable_wallet_card stops showing a customer
--      live progress toward a deleted bring-back rule.
--   7. Deleting an already-deleted program is refused (not a silent no-op), leaves the row and the
--      audit trail untouched, and never double-writes audit_log.
--   8. A non-owner (staff, or a total stranger) is refused, and a cross-tenant id is refused,
--      without mutating anything.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v332_retention_program_lifecycle.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole suite.
-- Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v332_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v332_out to public;

create or replace function pg_temp.as_v332_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v332_system() to public;

create or replace function pg_temp.as_v332_user(p_uid uuid, p_role text default 'authenticated')
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
grant execute on function pg_temp.as_v332_user(uuid,text) to public;

-- Some writer-guard triggers (e.g. trg_c45_loyalty_program_version_write_guard) require
-- auth.uid() to resolve to an owner, but 'authenticated' holds no direct table grant on the
-- table it guards (all real writes go through a SECURITY DEFINER RPC) -- so building that one
-- fixture row needs system-level table privilege AND an owner identity for auth.uid() at once.
create or replace function pg_temp.as_v332_system_acting_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.as_v332_system_acting_as(uuid) to public;

-- A minimal tenant: approved workspace, unpaused subscription, one owner, one non-owner staff
-- member, one client, and ONE live bring-back rule (goal_visits=1, period_days=1, credit
-- fulfillment) already PUBLISHED. retention_program_versions is immutable the moment its
-- config_version's status leaves 'draft' (trg_guard_retention_program_version), so the version row
-- has to be inserted while the header is still 'draft' and the header flipped to 'published'
-- afterwards -- unlike loyalty_tier_versions, a direct insert at an already-published header is
-- refused here.
create or replace function pg_temp.v332_tenant(
  p_business uuid, p_owner uuid, p_staff uuid, p_client uuid,
  p_config uuid, p_program uuid, p_taxonomy uuid, p_label text
) returns void language plpgsql as $$
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v332-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',p_staff,'authenticated','authenticated',
          'v332-staff-'||substr(p_staff::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business, p_label, lower(p_label)||'-'||substr(p_business::text,1,8),
          'retail','SGD', array['dashboard','clients','sales','loyalty']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v332 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V332 Owner',true,'approved'),
         (p_business,p_staff,'staff','V332 Staff',true,'approved');

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V332 Main',true,true);

  insert into public.staff_branches(business_id,staff_id,branch_id)
  select p_business, s.id, b.id
    from public.staff s, public.branches b
   where s.business_id=p_business and b.business_id=p_business;

  insert into public.clients(id,business_id,full_name)
  values (p_client,p_business,'V332 Client');

  insert into public.firm_config_versions(id,business_id,version_no,status,snapshot_hash)
  values (p_config,p_business,1,'draft',md5('v332-'||p_business::text));

  -- create_loyalty_config_draft (used by the resurrection-guard cells below) unconditionally
  -- clones from a loyalty_program_versions row at the base config version -- retention itself
  -- doesn't need one, but the draft-creation RPC does, so the fixture provides a minimal one.
  -- trg_c45_loyalty_program_version_write_guard requires an authenticated owner write for any
  -- insert while the config version is still 'draft' status, so this one statement runs as the
  -- owner rather than system.
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode,expiry_days,earn_points_per_dollar,
    current_config_version_id)
  values (p_business,'points',true,'points_tiers','published',100,500,'visits','none',null,1,p_config);
  perform pg_temp.as_v332_system_acting_as(p_owner);
  insert into public.loyalty_program_versions(
    business_id,config_version_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,tier_basis,expiry_mode,expiry_days)
  values (p_business,p_config,'points','points_tiers',true,1,100,500,'visits','none',null);
  perform pg_temp.as_v332_system();

  insert into public.firm_reward_taxonomy(id,business_id,label,fulfillment_kind,active,sort)
  values (p_taxonomy,p_business,'V332 Credit','credit',true,1);

  insert into public.retention_programs(
    id,business_id,name,goal_visits,period_days,reward_taxonomy_id,reward_type,
    reward_value,reward_item,starts_on,active,current_config_version_id
  ) values (
    p_program,p_business,'V332 Bring-back',1,1,p_taxonomy,'credit',500,null,
    date '2024-01-01',true,p_config
  );

  insert into public.retention_program_versions(
    program_id,config_version_id,business_id,name,active,goal_visits,period_days,
    starts_on,reward_taxonomy_id,fulfillment_kind,credit_cents,sort
  ) values (
    p_program,p_config,p_business,'V332 Bring-back',true,1,1,
    date '2024-01-01',p_taxonomy,'credit',500,1
  );

  update public.firm_config_versions
     set status='published', published_at=now()
   where id=p_config;
  update public.businesses set active_config_version_id=p_config where id=p_business;
end
$$;
grant execute on function pg_temp.v332_tenant(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text) to public;

do $v332_test$
declare
  bA uuid := gen_random_uuid(); oA uuid := gen_random_uuid(); stA uuid := gen_random_uuid();
  cA uuid := gen_random_uuid(); cfgA uuid := gen_random_uuid(); pA uuid := gen_random_uuid();
  taxA uuid := gen_random_uuid();
  bB uuid := gen_random_uuid(); oB uuid := gen_random_uuid(); stB uuid := gen_random_uuid();
  cB uuid := gen_random_uuid(); cfgB uuid := gen_random_uuid(); pB uuid := gen_random_uuid();
  taxB uuid := gen_random_uuid();
  v_starts_on date := date '2024-01-01';
  v_sale_a_at timestamptz; v_sale_b_at timestamptz; v_sale_c_at timestamptz;
  v_result jsonb; v_row public.retention_programs%rowtype; v_msg text;
  v_draft1 uuid; v_draft2 uuid; v_draft_active boolean;
  v_wallet jsonb;
  v_stranger uuid := gen_random_uuid();
begin
  v_sale_a_at := v_starts_on::timestamptz + interval '2 hours';         -- period_index 0
  v_sale_b_at := v_starts_on::timestamptz + interval '1 day 2 hours';   -- period_index 1
  v_sale_c_at := v_starts_on::timestamptz + interval '2 days 2 hours';  -- period_index 2

  perform pg_temp.as_v332_system();
  perform pg_temp.v332_tenant(bA, oA, stA, cA, cfgA, pA, taxA, 'V332 Alpha');
  perform pg_temp.v332_tenant(bB, oB, stB, cB, cfgB, pB, taxB, 'V332 Beta');

  -- CELL 1: deleted_at exists, nullable, defaults null.
  begin
    perform 1 from information_schema.columns
     where table_schema='public' and table_name='retention_programs' and column_name='deleted_at'
       and is_nullable='YES';
    if found then
      insert into v332_out values (1,'deleted_at column exists & nullable','PASS');
    else
      insert into v332_out values (1,'deleted_at column exists & nullable','FAIL - missing or not nullable');
    end if;
  end;
  select * into v_row from public.retention_programs where id=pA;
  if v_row.deleted_at is null then
    insert into v332_out values (2,'fixture program defaults deleted_at to null','PASS');
  else
    insert into v332_out values (2,'fixture program defaults deleted_at to null','FAIL - '||v_row.deleted_at::text);
  end if;

  -- CELL 3: sale A (period 0) meets goal_visits=1 while the program is still live -- posts a
  -- reward_grants row AND a credit_ledger row (fulfillment_kind='credit').
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at,occurred_at)
  values (gen_random_uuid(),bA,cA,'service',1000,false,true,true,cfgA,now(),v_sale_a_at);
  if exists(select 1 from public.reward_grants where business_id=bA and program_id=pA and period_index=0)
     and exists(select 1 from public.credit_ledger where business_id=bA and client_id=cA
                  and reference='retention reward: V332 Bring-back') then
    insert into v332_out values (3,'pre-delete qualifying sale grants a reward + posts credit','PASS');
  else
    insert into v332_out values (3,'pre-delete qualifying sale grants a reward + posts credit','FAIL - grant or credit missing');
  end if;

  -- CELL 4: CORRECTNESS GATE PART 2, baseline -- before delete, the customer wallet card shows
  -- 1 visit remaining toward the (not-yet-reached) period-1 window.
  perform pg_temp.as_v332_system();
  select app.c45_base_actionable_wallet_card(bA,cA,'v332-alpha','V332 Alpha','retail','SGD',
    array['dashboard','clients','sales','loyalty'],v_sale_b_at) into v_wallet;
  if (v_wallet->>'visits_remaining')='1' then
    insert into v332_out values (4,'baseline: wallet card shows 1 visit remaining pre-delete','PASS');
  else
    insert into v332_out values (4,'baseline: wallet card shows 1 visit remaining pre-delete','FAIL - '||v_wallet::text);
  end if;

  -- CELL 5: owner deletes the program -- active=false AND deleted_at set.
  perform pg_temp.as_v332_user(oA);
  select public.business_delete_retention_program_v332(bA, pA) into v_result;
  perform pg_temp.as_v332_system();
  select * into v_row from public.retention_programs where id=pA;
  if v_row.active=false and v_row.deleted_at is not null and (v_result->>'status')='ok' then
    insert into v332_out values (5,'owner delete sets active=false + deleted_at','PASS');
  else
    insert into v332_out values (5,'owner delete sets active=false + deleted_at',
      format('FAIL - active=%s deleted_at=%s status=%s',v_row.active,v_row.deleted_at,v_result->>'status'));
  end if;

  -- CELL 9: CORRECTNESS GATE PART 2 -- re-check the wallet card BEFORE the period-1 sale exists
  -- (the same moment cell 4's baseline was taken): visits_remaining must fold to JSON null now
  -- that the program is deleted, not merely count down. This has to run before cell 6's sale
  -- below, or the sale itself (still recorded even though it earns no reward) would put a real
  -- row back in the window and mask a broken deleted_at filter behind a coincidental 0.
  select app.c45_base_actionable_wallet_card(bA,cA,'v332-alpha','V332 Alpha','retail','SGD',
    array['dashboard','clients','sales','loyalty'],v_sale_b_at) into v_wallet;
  if (v_wallet->>'visits_remaining') is null then
    insert into v332_out values (9,'CORRECTNESS GATE: wallet card no longer shows progress toward the deleted rule','PASS');
  else
    insert into v332_out values (9,'CORRECTNESS GATE: wallet card no longer shows progress toward the deleted rule','FAIL - '||v_wallet::text);
  end if;

  -- CELL 6: THE CORRECTNESS GATE PART 1 -- a second qualifying sale, in a brand-new period (1),
  -- AFTER the delete must NOT grant a new reward, even though the currently-published
  -- retention_program_versions snapshot row still says active=true underneath (it is immutable
  -- and was never touched).
  perform pg_temp.as_v332_system();
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at,occurred_at)
  values (gen_random_uuid(),bA,cA,'service',1000,false,true,true,cfgA,now(),v_sale_b_at);
  if not exists(select 1 from public.reward_grants where business_id=bA and program_id=pA and period_index=1) then
    insert into v332_out values (6,'CORRECTNESS GATE: post-delete qualifying sale grants nothing','PASS');
  else
    insert into v332_out values (6,'CORRECTNESS GATE: post-delete qualifying sale grants nothing','FAIL - a new grant was posted');
  end if;
  if exists(select 1 from public.retention_program_versions
             where program_id=pA and config_version_id=cfgA and active) then
    insert into v332_out values (7,'the published snapshot row is untouched (still active=true, immutable)','PASS');
  else
    insert into v332_out values (7,'the published snapshot row is untouched (still active=true, immutable)','FAIL - snapshot was mutated');
  end if;

  -- CELL 8: deleting must never touch history -- sale A's grant and credit_ledger row from before
  -- the delete are exactly as they were.
  if (select count(*) from public.reward_grants where business_id=bA and program_id=pA and period_index=0)=1
     and (select count(*) from public.credit_ledger where business_id=bA and client_id=cA
            and reference='retention reward: V332 Bring-back')=1 then
    insert into v332_out values (8,'pre-delete reward_grants/credit_ledger rows are untouched by the delete','PASS');
  else
    insert into v332_out values (8,'pre-delete reward_grants/credit_ledger rows are untouched by the delete','FAIL - history changed');
  end if;

  -- CELL 10: re-delete of an already-deleted program is refused (not a silent no-op), and does not
  -- double-write audit_log.
  perform pg_temp.as_v332_user(oA);
  begin
    perform public.business_delete_retention_program_v332(bA, pA);
    insert into v332_out values (10,'re-delete of an already-deleted program is refused','FAIL - no exception raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like '%already deleted%' then
      insert into v332_out values (10,'re-delete of an already-deleted program is refused','PASS');
    else
      insert into v332_out values (10,'re-delete of an already-deleted program is refused','FAIL - wrong message: '||v_msg);
    end if;
  end;
  perform pg_temp.as_v332_system();
  if (select count(*) from public.audit_log where business_id=bA and action='DELETE_RETENTION_PROGRAM' and entity_id=pA)=1 then
    insert into v332_out values (11,'re-delete attempt did not double-write audit_log','PASS');
  else
    insert into v332_out values (11,'re-delete attempt did not double-write audit_log','FAIL - wrong audit_log row count');
  end if;

  -- CELL 12-15: THE RESURRECTION GUARD, using a SECOND live program on tenant Beta so the delete
  -- happens while a draft is genuinely open beforehand (the exact "hard part" scenario).
  perform pg_temp.as_v332_user(oB);
  select public.create_loyalty_config_draft(bB, cfgB, 'v332_test') into v_result;
  v_draft1 := (v_result->>'version_id')::uuid;
  select active from public.retention_program_versions
   where program_id=pB and config_version_id=v_draft1 into v_draft_active;
  if v_draft_active=true then
    insert into v332_out values (12,'draft opened BEFORE the delete clones an active=true row','PASS');
  else
    insert into v332_out values (12,'draft opened BEFORE the delete clones an active=true row','FAIL - active='||coalesce(v_draft_active::text,'<null>'));
  end if;

  select public.business_delete_retention_program_v332(bB, pB) into v_result;
  select active from public.retention_program_versions
   where program_id=pB and config_version_id=v_draft1 into v_draft_active;
  if v_draft_active=false then
    insert into v332_out values (13,'delete flips the already-open draft''s own row to active=false','PASS');
  else
    insert into v332_out values (13,'delete flips the already-open draft''s own row to active=false','FAIL - active='||coalesce(v_draft_active::text,'<null>'));
  end if;

  -- Deliberately simulate the worst case: force the (still-draft, still-mutable) row back to
  -- active=true, as if the RPC's own draft patch above had never happened, to isolate and prove
  -- publish_loyalty_config's OWN guard independently.
  perform pg_temp.as_v332_system();
  update public.retention_program_versions set active=true
   where program_id=pB and config_version_id=v_draft1;
  perform pg_temp.as_v332_user(oB);
  select public.publish_loyalty_config(v_draft1) into v_result;
  if (v_result->>'status')='published' then
    insert into v332_out values (14,'publishing the draft (with its row forced back to active=true) succeeds','PASS');
  else
    insert into v332_out values (14,'publishing the draft (with its row forced back to active=true) succeeds','FAIL - '||v_result::text);
  end if;
  perform pg_temp.as_v332_system();
  select * into v_row from public.retention_programs where id=pB;
  if v_row.active=false and v_row.deleted_at is not null then
    insert into v332_out values (15,'RESURRECTION GUARD: publish_loyalty_config keeps the deleted program dead','PASS');
  else
    insert into v332_out values (15,'RESURRECTION GUARD: publish_loyalty_config keeps the deleted program dead',
      format('FAIL - active=%s deleted_at=%s (publish resurrected it)',v_row.active,v_row.deleted_at));
  end if;

  -- End-to-end double-check: even against the now-published v_draft1 (whose own snapshot row still
  -- literally says active=true), a fresh qualifying sale still grants nothing -- on_sale_recorded's
  -- own independent deleted_at check is the thing actually stopping it, not just the publish force.
  insert into public.sales(id,business_id,client_id,kind,amount_cents,earns_points,
                           counts_as_visit,counts_as_revenue,config_version_id,policy_resolved_at,occurred_at)
  values (gen_random_uuid(),bB,cB,'service',1000,false,true,true,v_draft1,now(),v_sale_c_at);
  if not exists(select 1 from public.reward_grants where business_id=bB and program_id=pB) then
    insert into v332_out values (16,'end-to-end: still no grant after publishing a draft with a stale active=true row','PASS');
  else
    insert into v332_out values (16,'end-to-end: still no grant after publishing a draft with a stale active=true row','FAIL - a grant was posted');
  end if;

  -- CELL 17: a BRAND NEW draft opened AFTER the delete never even clones a row for the deleted
  -- program (app.clone_retention_program_versions_on_draft's own deleted_at exclusion).
  perform pg_temp.as_v332_user(oB);
  select public.create_loyalty_config_draft(bB, v_draft1, 'v332_test') into v_result;
  v_draft2 := (v_result->>'version_id')::uuid;
  if not exists(select 1 from public.retention_program_versions where program_id=pB and config_version_id=v_draft2) then
    insert into v332_out values (17,'a draft opened after the delete never clones a row for the deleted program','PASS');
  else
    insert into v332_out values (17,'a draft opened after the delete never clones a row for the deleted program','FAIL - a row was cloned');
  end if;

  -- CELL 18-20: authorization -- a non-owner staff member and a total stranger are both refused,
  -- and a cross-tenant delete is refused, without mutating anything.
  perform pg_temp.as_v332_user(stA);
  begin
    perform public.business_delete_retention_program_v332(bA, pA);
    insert into v332_out values (18,'non-owner staff member is refused','FAIL - no exception raised');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like '%owner only%' then
      insert into v332_out values (18,'non-owner staff member is refused','PASS');
    else
      insert into v332_out values (18,'non-owner staff member is refused','FAIL - wrong message: '||v_msg);
    end if;
  end;

  perform pg_temp.as_v332_system();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_stranger,'authenticated','authenticated',
          'v332-stranger@example.test','',now(),now(),now()) on conflict (id) do nothing;
  perform pg_temp.as_v332_user(v_stranger);
  begin
    perform public.business_delete_retention_program_v332(bB, pB);
    insert into v332_out values (19,'a total stranger (no staff row anywhere) is refused','FAIL - no exception raised');
  exception when others then
    insert into v332_out values (19,'a total stranger (no staff row anywhere) is refused','PASS');
  end;

  perform pg_temp.as_v332_user(oA);
  begin
    perform public.business_delete_retention_program_v332(bA, pB);
    insert into v332_out values (20,'cross-tenant delete (Alpha owner, Beta program) is refused','FAIL - no exception raised');
  exception when others then
    insert into v332_out values (20,'cross-tenant delete (Alpha owner, Beta program) is refused','PASS');
  end;
end
$v332_test$;

select seq, step, outcome from v332_out order by seq;

rollback;
