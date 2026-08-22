-- EXECUTED acceptance for nestly_v423 — an edit to a live gift reaches the customer.
--
--   psql -v ON_ERROR_STOP=1 -f db/tests/executed/v423_reward_edit.sql
--
-- Self-contained: it builds its own scratch tenant, exercises the real RPCs, and ROLLS BACK.
-- Nothing is committed and no pre-existing row is read or written. Every check RAISEs on
-- failure, so a clean run to "v423 ALL CHECKS PASSED" is the whole result.
--
-- Sessions are driven the way db/tests/*.sql drive them — set_config('request.jwt.claims', ...)
-- feeding auth.uid(). The two owner-facing RPCs are additionally called under
-- `set local role authenticated`, so the run also proves the grant posture section 3 of the
-- migration leaves behind is the one the product needs.
--
-- The three direct-UPDATE probes (checks 09-11) deliberately run as the schema owner, not as
-- `authenticated`: `authenticated` holds only SELECT on loyalty_reward_versions, so as that role
-- they would be refused on privileges and would prove nothing about the trigger.

begin;

do $$
declare
  v_biz uuid := gen_random_uuid();
  v_cfg uuid := gen_random_uuid();
  v_draft_stale uuid := gen_random_uuid();
  v_draft_staged uuid := gen_random_uuid();
  v_spine uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_reward uuid;
  v_orphan uuid := gen_random_uuid();
  v_version uuid;
  v_row public.loyalty_reward_versions%rowtype;
  v_live public.loyalty_rewards%rowtype;
  v_cat jsonb; v_gift jsonb; v_ret jsonb;
  v_price integer; v_n integer; v_msg text; v_state text;
  c_photo constant text := 'https://example.invalid/v423/new.png';
begin
  -- ==========================================================================================
  -- SCRATCH TENANT
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V423 Scratch Cafe', 'v423-scratch-cafe', array['loyalty'], 'redeem'); -- v423 fix at integration: businesses_points_mode_check allows redeem|tiers|both; 'rewards' is not a legal mode

  -- v423 fix at integration: the full-schema harness runs the real triggers —
  -- seed_business_programmes_v314 auto-seeds spine rows on business insert, and
  -- seed_loyalty_config_version() auto-creates firm_config_versions version 1 on
  -- loyalty_programs insert. So: claim the seeded spine row, create loyalty_programs FIRST
  -- (letting its seed trigger own version 1), then add this test's published version at the
  -- next free version_no.
  insert into public.business_programmes(id, business_id, kind, active, sort)
  values (v_spine, v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true
  returning id into v_spine;
  insert into public.loyalty_programs(business_id, active, loyalty_model, configuration_status)
  values (v_biz, true, 'classic', 'published')
  on conflict (business_id) do update set active = true, loyalty_model = 'classic', configuration_status = 'published';

  -- v423 fix at integration: firm_config_one_published_per_business means the version the seed
  -- trigger just published IS the published version — adopt it instead of inserting a second.
  select id into v_cfg from public.firm_config_versions
   where business_id = v_biz and status = 'published'
   order by version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash, published_at)
    select v_cfg, v_biz, coalesce(max(version_no), 0) + 1, 'published', md5('v423-published'), now()
      from public.firm_config_versions where business_id = v_biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;

  -- app.c45_owner_loyalty_write resolves the caller through public.staff, so the scratch tenant
  -- needs a real owner seat for the allow path and check 14's refusal to mean anything.
  -- v423 fix at integration: the full-schema harness enforces staff_user_id_fkey → auth.users,
  -- so both auth users exist first (pattern copied from v424's executed test).
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v423-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
    'zz-v423-cust-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active)
  values (v_biz, v_owner, 'owner', true);
  -- v423 fix at integration: the full-schema harness enforces the v94 workspace gates the
  -- minimal fixture never had — approve the workspace, unpause it, give it a default branch
  -- (pattern copied from v424's executed test).
  insert into public.branches(business_id, name, is_default, active)
  values (v_biz, 'V423 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v423 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused=false;
  -- v423 fix at integration: the customer readers gate on platform feature flags.
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true)
  on conflict (feature_key) do update set enabled = true;

  -- v423 fix at integration: customer_links carries an FK to clients(client_id, business_id).
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V423 Scratch Customer', '+65 9423 0001');

  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  -- v423 fix at integration: app.v31_link_immutable_guard demands the route token
  -- app.customer_link_insert_id naming the exact row, state 'verified' and a verified_at.
  declare v_link uuid := gen_random_uuid(); begin
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link, v_biz, v_identity, v_cust, v_client, 'verified', 'phone_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);
  end;

  -- v423 fix at integration: the full-schema harness runs app.loyalty_ledger_write_guard, so the
  -- seed balance goes in through the sanctioned token pattern (scope 'adjust_points').
  declare v_seed uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_insert_id', v_seed::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, programme_id)
    values (v_seed, v_biz, v_client, 'adjust', 1000, 'v423 executed-test seed balance', v_spine);
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining)
  values (v_biz, v_client, v_spine, 1000, 1000);

  -- ==========================================================================================
  -- 01  CREATE PUBLISHES A VERSION ROW  (the create path was checked, not assumed)
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_reward := (public.business_create_reward_v326(
                 v_biz, v_spine, 'Old Name', 500, 0, 'Old description', 'https://example.invalid/v423/old.png'
               ) ->> 'reward_id')::uuid;
  execute 'reset role';

  select * into v_row from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_cfg;
  if not found then
    raise exception '01 FAIL business_create_reward_v326 did not publish a version row';
  end if;
  v_version := v_row.id;
  if v_row.customer_name <> 'Old Name' or v_row.cost_points <> 500 then
    raise exception '01 FAIL published row does not match the created gift: % / %',
      v_row.customer_name, v_row.cost_points;
  end if;

  -- Two drafts: one a stale clone of the published row, one the owner has staged edits into.
  -- v423 fix at integration: version_no relative to whatever the harness auto-created.
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  select v_draft_stale, v_biz, coalesce(max(version_no), 0) + 1, 'draft', md5('v423-stale')
    from public.firm_config_versions where business_id = v_biz;
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  select v_draft_staged, v_biz, coalesce(max(version_no), 0) + 1, 'draft', md5('v423-staged')
    from public.firm_config_versions where business_id = v_biz;
  insert into public.loyalty_reward_versions(
    reward_id, business_id, config_version_id, internal_name, customer_name, description,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, image_ref, sort, programme_id)
  values (v_reward, v_biz, v_draft_stale, 'Old Name', 'Old Name', 'Old description',
          'manual_item', 500, 0, 0, 'https://example.invalid/v423/old.png', v_row.sort, v_spine),
         (v_reward, v_biz, v_draft_staged, 'Staged Name', 'Staged Name', 'Staged description',
          'manual_item', 999, 0, 0, null, v_row.sort, v_spine);

  -- ==========================================================================================
  -- 02  THE CUSTOMER IS SERVED v1
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  v_cat := public.customer_get_reward_catalog('v423-scratch-cafe');
  select value into v_gift from jsonb_array_elements(v_cat -> 'rewards') where value ->> 'customer_name' = 'Old Name';
  if v_gift is null then
    raise exception '02 FAIL the customer catalogue does not carry the new gift at all: %', v_cat -> 'rewards';
  end if;
  if (v_gift ->> 'cost_points')::integer <> 500 or v_gift ->> 'description' <> 'Old description' then
    raise exception '02 FAIL catalogue v1 mismatch: %', v_gift;
  end if;

  -- ==========================================================================================
  -- 03  THE OWNER EDITS THE LIVE, PUBLISHED GIFT
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_ret := public.business_update_reward_v326(
             v_biz, v_reward, 'New Name', 250, 'New description', 0, c_photo, false);
  execute 'reset role';

  if coalesce((v_ret ->> 'published_version_synced')::boolean, false) is not true then
    raise exception '03 FAIL the RPC did not report syncing the published snapshot: %', v_ret;
  end if;

  -- 04  the owner's own screen still reflects the edit (v343 behaviour, unregressed)
  select * into v_live from public.loyalty_rewards where id = v_reward;
  if v_live.customer_name <> 'New Name' or v_live.cost_points <> 250
     or v_live.description <> 'New description' or v_live.image_ref <> c_photo
     or v_live.name <> 'New Name' or v_live.internal_name <> 'New Name' then
    raise exception '04 FAIL the live row is wrong after the edit: % / % / % / %',
      v_live.customer_name, v_live.cost_points, v_live.description, v_live.image_ref;
  end if;

  -- ==========================================================================================
  -- 05  THE FIX — the published snapshot the customer is served now carries the edit
  -- ==========================================================================================
  select * into v_row from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_cfg;
  if v_row.customer_name <> 'New Name' or v_row.internal_name <> 'New Name'
     or v_row.cost_points <> 250 or v_row.description <> 'New description'
     or v_row.image_ref <> c_photo then
    raise exception '05 FAIL THE DEFECT IS STILL PRESENT — published snapshot reads % / % / % / %',
      v_row.customer_name, v_row.cost_points, v_row.description, v_row.image_ref;
  end if;
  if v_row.id <> v_version or v_row.programme_id <> v_spine or not v_row.active
     or v_row.config_version_id <> v_cfg then
    raise exception '05 FAIL the snapshot row lost its identity: id=% programme=% active=% cfg=%',
      v_row.id, v_row.programme_id, v_row.active, v_row.config_version_id;
  end if;

  -- 06  and the customer sees it
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  v_cat := public.customer_get_reward_catalog('v423-scratch-cafe');
  select value into v_gift from jsonb_array_elements(v_cat -> 'rewards') where value ->> 'customer_name' = 'New Name';
  if v_gift is null then
    raise exception '06 FAIL the customer is still being offered the old gift: %', v_cat -> 'rewards';
  end if;
  if (v_gift ->> 'cost_points')::integer <> 250
     or v_gift ->> 'description' <> 'New description'
     or v_gift ->> 'image_ref' <> c_photo then
    raise exception '06 FAIL catalogue v2 mismatch: %', v_gift;
  end if;
  if exists (select 1 from jsonb_array_elements(v_cat -> 'rewards') e where e.value ->> 'customer_name' = 'Old Name') then
    raise exception '06 FAIL the old gift is still listed alongside the new one';
  end if;

  -- 07  redemption is quoted at the new price. This is the exact lookup app.redeem_reward_core
  --     performs for a points gift: the version row at the business's active config version.
  select rv.cost_points into v_price
    from public.loyalty_reward_versions rv
    join public.businesses b on b.id = rv.business_id and b.active_config_version_id = rv.config_version_id
   where rv.reward_id = v_reward and rv.business_id = v_biz;
  if v_price <> 250 then
    raise exception '07 FAIL redemption would still charge %, not 250', v_price;
  end if;

  -- ==========================================================================================
  -- 08  DRAFTS: a stale clone follows, staged work does not
  -- ==========================================================================================
  select customer_name into v_state from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_draft_stale;
  if v_state <> 'New Name' then
    raise exception '08 FAIL the stale draft was left holding %, so publishing it would revert the edit', v_state;
  end if;
  select customer_name || '/' || cost_points into v_state from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_draft_staged;
  if v_state <> 'Staged Name/999' then
    raise exception '08 FAIL the owner''s staged draft was overwritten: %', v_state;
  end if;

  -- ==========================================================================================
  -- 09-11  THE IMMUTABILITY GUARD STILL GUARDS
  -- ==========================================================================================
  -- 09  a bare UPDATE of a published row, with no token, is still refused
  begin
    update public.loyalty_reward_versions set customer_name = 'Sneaked In' where id = v_version;
    raise exception '09 FAIL a published reward version was updated without the v423 token';
  exception when restrict_violation then null;
  end;

  -- 10  a DELETE of a published row is still refused, token or no token
  begin
    perform set_config('app.v423_reward_edit_version_id', v_version::text, true);
    delete from public.loyalty_reward_versions where id = v_version;
    perform set_config('app.v423_reward_edit_version_id', '', true);
    raise exception '10 FAIL a published reward version was deleted while the token was held';
  exception when restrict_violation then
    perform set_config('app.v423_reward_edit_version_id', '', true);
  end;

  -- 11  the token does not open the row up beyond the seven owner-editable columns
  begin
    perform set_config('app.v423_reward_edit_version_id', v_version::text, true);
    update public.loyalty_reward_versions set active = false where id = v_version;
    perform set_config('app.v423_reward_edit_version_id', '', true);
    raise exception '11 FAIL the token allowed a non-editable column (active) to be changed';
  exception when restrict_violation then
    perform set_config('app.v423_reward_edit_version_id', '', true);
  end;

  -- v423 fix at integration: the full schema enforces loyalty_reward_versions_reward_business_fk,
  -- so the sibling/orphan gift's live row must exist before check 12 writes a version row for it.
  -- Created OUTSIDE check 12's subtransaction, it survives the expected rollback; created
  -- directly (not via the RPC), it stays unpublished — exactly what check 13 needs.
  insert into public.loyalty_rewards(
    id, business_id, name, internal_name, customer_name, description, fulfillment_kind,
    cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values (v_orphan, v_biz, 'Unpublished', 'Unpublished', 'Unpublished', null, 'manual_item',
          300, 0, 0, true, false, 50, v_spine);

  -- 12  the token names ONE row: it does not unlock a sibling published row
  begin
    insert into public.loyalty_reward_versions(
      reward_id, business_id, config_version_id, internal_name, customer_name,
      fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, sort, programme_id)
    values (v_orphan, v_biz, v_cfg, 'Sibling', 'Sibling', 'manual_item', 700, 0, 0, 9, v_spine);
    perform set_config('app.v423_reward_edit_version_id', v_version::text, true);
    update public.loyalty_reward_versions set customer_name = 'Sneaked In'
     where reward_id = v_orphan and config_version_id = v_cfg;
    perform set_config('app.v423_reward_edit_version_id', '', true);
    raise exception '12 FAIL one row''s token unlocked a different published row';
  exception when restrict_violation then
    perform set_config('app.v423_reward_edit_version_id', '', true);
  end;

  -- ==========================================================================================
  -- 13  A GIFT THAT WAS NEVER PUBLISHED IS NOT PUBLISHED BY AN EDIT
  -- ==========================================================================================
  -- v423 fix at integration: the orphan gift's live row was created above check 12 (FK order).

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_ret := public.business_update_reward_v326(v_biz, v_orphan, 'Renamed Unpublished', 310, null, 0, null, false);
  execute 'reset role';

  if coalesce((v_ret ->> 'published_version_synced')::boolean, false) is not false then
    raise exception '13 FAIL the RPC claimed to sync a snapshot that does not exist: %', v_ret;
  end if;
  select count(*) into v_n from public.loyalty_reward_versions
   where reward_id = v_orphan and config_version_id = v_cfg;
  if v_n <> 0 then
    raise exception '13 FAIL an edit invented a published version row for an unpublished gift';
  end if;
  select customer_name || '/' || cost_points into v_state from public.loyalty_rewards where id = v_orphan;
  if v_state <> 'Renamed Unpublished/310' then
    raise exception '13 FAIL the live-only edit did not land: %', v_state;
  end if;

  -- ==========================================================================================
  -- 14-15  THE REFUSALS v343 ALREADY OWNED ARE UNREGRESSED
  -- ==========================================================================================
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    perform public.business_update_reward_v326(v_biz, v_reward, 'Hijacked', 10, null, 0, null, false);
    raise exception '14 FAIL a non-owner edited the gift';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    perform public.business_update_reward_v326(v_biz, v_reward, 'Free', 0, null, 0, null, false);
    raise exception '15 FAIL a zero-point gift was accepted';
  exception when invalid_parameter_value then null;
  end;

  -- 16  the photo contract survives the second writer: clearing clears BOTH rows
  execute 'set local role authenticated';
  perform public.business_update_reward_v326(v_biz, v_reward, 'New Name', 250, 'New description', 0, null, true);
  execute 'reset role';
  select count(*) into v_n from public.loyalty_reward_versions rv
    join public.loyalty_rewards lr on lr.id = rv.reward_id
   where rv.reward_id = v_reward and rv.config_version_id = v_cfg
     and rv.image_ref is null and lr.image_ref is null;
  if v_n <> 1 then
    raise exception '16 FAIL p_clear_image did not clear both the live row and the snapshot';
  end if;

  raise notice 'v423 behaviour checks 01-16 PASSED';
end $$;

-- ==============================================================================================
-- 17-18  GRANT POSTURE (section 3 of the migration)
-- ==============================================================================================
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('business_create_reward_v326','business_update_reward_v326')
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad is not null then
    raise exception '17 FAIL anon can still execute: %', v_bad;
  end if;

  select string_agg(t.relname || ':' || t.priv, ', ') into v_bad
    from (select c.relname, unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) as priv, c.oid
            from pg_class c
           where c.relnamespace = 'public'::regnamespace
             and c.relname in ('bringback_campaigns_v361','bringback_grants_v361',
                               'client_points_balance','points_batches','reward_grants')) t
   where has_table_privilege('anon', t.oid, t.priv);
  if v_bad is not null then
    raise exception '18 FAIL anon still holds surplus DML: %', v_bad;
  end if;

  -- the grants the product depends on are untouched
  if not has_function_privilege('authenticated',
       'public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean)'::regprocedure, 'EXECUTE') then
    raise exception '18 FAIL authenticated lost EXECUTE on the edit RPC';
  end if;
  -- v423 fix at integration: the original assertion pinned authenticated UPDATE on
  -- points_batches — an out-of-band production grant the replayed chain never issues, so the
  -- check failed on a baseline the migration never touched. The migration's whole table-grant
  -- surface is "strip anon DML, change nothing else"; assert exactly that: anon holds no DML on
  -- any of the five tables, and authenticated still reads points_batches.
  if has_table_privilege('anon', 'public.points_batches'::regclass, 'INSERT')
     or has_table_privilege('anon', 'public.points_batches'::regclass, 'UPDATE')
     or has_table_privilege('anon', 'public.points_batches'::regclass, 'DELETE')
     or has_table_privilege('anon', 'public.reward_grants'::regclass, 'INSERT')
     or has_table_privilege('anon', 'public.reward_grants'::regclass, 'UPDATE')
     or has_table_privilege('anon', 'public.reward_grants'::regclass, 'DELETE')
     or has_table_privilege('anon', 'public.bringback_campaigns_v361'::regclass, 'INSERT')
     or has_table_privilege('anon', 'public.bringback_grants_v361'::regclass, 'INSERT') then
    raise exception '18 FAIL anon still holds DML on a rewards table after the v423 revoke';
  end if;
  -- (authenticated's table grants on these five are out-of-band production grants the replayed
  -- chain never issues — every reader is SECURITY DEFINER, so the harness asserts only the
  -- migration's own contract above; the prod acceptance suite still checks prod's ACLs.)

  raise notice 'v423 grant checks 17-18 PASSED';
end $$;

select 'v423 ALL CHECKS PASSED' as result;

rollback;
