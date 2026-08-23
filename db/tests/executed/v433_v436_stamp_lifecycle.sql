-- EXECUTED acceptance for the nestly_v433–v436 stamp lifecycle wave — the owner's locked rules,
-- exercised end to end through the real RPCs (owner tests A–F, directive 2026-08-22):
--
--   A  a mid-card edit never touches the customer's open card (v433 version split)
--   B  a two-part edit pends, then publishes as ONE new version; the open card never moves
--   C  the earn rate is pinned to the card, not to the newest publish (v436); completion moves
--      the customer straight onto the LATEST setup
--   D  a card expires on ITS OWN version's validity; already-earned milestones survive and stay
--      claimable — including while the programme is switched OFF (v435, rules 4/5/7)
--   E  a points-expiry rule change never rewrites existing batches (rule 8/9)
--   F  a draft declaring points publishes while stamps still runs, and its gifts bind to the
--      declared programme — the wizard switch path, no workaround (v434, rule 12)
--   G  history rows keep the unit they happened in — a stamp earn stays "stamps" whatever the
--      live programme says today (v437, rule 13)
--
--   psql -v ON_ERROR_STOP=1 -f db/tests/executed/v433_v436_stamp_lifecycle.sql
--
-- Dual-mode: BASELINE pins the defects (the in-place edit P0, the inert length/rate writes, the
-- auto-tagged wizard gift + blocked publish, no expiry machinery at all). MIGRATED pins the fix.
--
-- HARNESS: PHASED-COMMITS
-- STRUCTURE NOTE — phases COMMIT (no rollback): now() is transaction-fixed, and the version
-- pin, the expiry clock and published_at ordering are all time-ordered. One giant transaction
-- collapses every event onto a single instant and the ordering degenerates into ties production
-- never sees. The harness gives this file its own throwaway database, so committing is safe and
-- each phase gets a real, later timestamp — the temporal shape production actually has.

create temp table _ctx(k text primary key, v text);

-- ============================================================================================
-- PHASE 0 — scratch tenant (recipe proven by v432's executed test)
-- ============================================================================================
begin;
do $$
declare
  v_biz uuid := gen_random_uuid();
  v_cfg uuid;
  v_spine_stamps uuid := gen_random_uuid();
  v_spine_points uuid;
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_client2 uuid := gen_random_uuid();
  v_reward_free uuid := gen_random_uuid();
  v_reward_big uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_n integer;
begin
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V433 Scratch Kopi', 'v433-scratch-kopi', array['loyalty'], 'redeem');
  insert into public.business_programmes(id, business_id, kind, active, sort)
  values (v_spine_stamps, v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true
  returning id into v_spine_stamps;
  update public.business_programmes set active = false
   where business_id = v_biz and kind = 'points';
  select id into v_spine_points from public.business_programmes
   where business_id = v_biz and kind = 'points';

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v433-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
    'zz-v433-cust-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V433 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v433 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused=false;
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.loyalty_programs(business_id, active, loyalty_model, kind, configuration_status,
                                      stamp_target, stamp_per_cents)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500)
  on conflict (business_id) do update
    set active=true, loyalty_model='stamps', kind='stamps',
        configuration_status='published', stamp_target=5, stamp_per_cents=500;
  select id into v_cfg from public.firm_config_versions
   where business_id = v_biz and status = 'published' order by version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash, published_at)
    select v_cfg, v_biz, coalesce(max(version_no), 0) + 1, 'published', md5('v433-published'), now()
      from public.firm_config_versions where business_id = v_biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;
  select stamp_target into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg and business_id = v_biz;
  if v_n is distinct from 5 then
    raise exception 'FIXTURE BROKEN: version 1 carries stamp_target % (expected 5)', v_n;
  end if;

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V433 Customer One', '+65 9433 0001'),
         (v_client2, v_biz, 'V433 Customer Two', '+65 9433 0002');
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  declare v_link uuid := gen_random_uuid(); begin
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link, v_biz, v_identity, v_cust, v_client, 'verified', 'phone_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);
  end;

  -- Client 1: 4 stamps on the open card (Free Coffee @3 earned, Big Gift @5 not yet).
  perform app.acquire_loyalty_shared_v480(v_biz);
  declare v_seed uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_insert_id', v_seed::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id)
    values (v_seed, v_biz, v_client, 'adjust', 4, 'v433 seed stamps', v_owner, v_spine_stamps);
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining)
  values (v_biz, v_client, v_spine_stamps, 4, 4);

  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values
    (v_reward_free, v_biz, 'Free Coffee', 'Free Coffee', 'Free Coffee', 'manual_item', 3, 0, 0, true, false, 1, v_spine_stamps),
    (v_reward_big,  v_biz, 'Big Gift',    'Big Gift',    'Big Gift',    'manual_item', 5, 0, 0, true, false, 2, v_spine_stamps);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, description, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, image_ref, sort, programme_id)
  values
    (v_reward_free, v_biz, v_cfg, 'Free Coffee', 'Free Coffee', 'Mid-card', 'manual_item', 3, 0, 0, null, 1, v_spine_stamps),
    (v_reward_big,  v_biz, v_cfg, 'Big Gift',    'Big Gift',    'Final',    'manual_item', 5, 0, 0, null, 2, v_spine_stamps);

  insert into _ctx values
    ('biz', v_biz::text), ('cfg', v_cfg::text), ('spine_stamps', v_spine_stamps::text),
    ('spine_points', v_spine_points::text), ('owner', v_owner::text), ('cust', v_cust::text),
    ('client', v_client::text), ('client2', v_client2::text),
    ('reward_free', v_reward_free::text), ('reward_big', v_reward_big::text),
    ('branch', v_branch::text);
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE A — MID-CARD EDIT (owner test A): rename Free Coffee → Espresso Shot, cost 3 → 4
-- ============================================================================================
begin;
do $$
declare
  v433 boolean := position('stamp_config_edit_begin_v433' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='business_update_reward_v326'), '')) > 0;
  v_biz uuid := (select v from _ctx where k='biz');
  v_cfg uuid := (select v from _ctx where k='cfg');
  v_owner uuid := (select v from _ctx where k='owner');
  v_cust uuid := (select v from _ctx where k='cust');
  v_reward_free uuid := (select v from _ctx where k='reward_free');
  v_res jsonb; v_json jsonb; v_txt text; v_ver_b uuid; v_uuid uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_res := public.business_update_reward_v326(v_biz, v_reward_free, 'Espresso Shot', 4, null, 0, null, false);

  if v433 then
    if not coalesce((v_res->>'version_split')::boolean, false) then
      raise exception 'A FAIL (migrated): a stamp edit over an open card did not split the version: %', v_res;
    end if;
    select active_config_version_id into v_ver_b from public.businesses where id = v_biz;
    if v_ver_b is null or v_ver_b = v_cfg then
      raise exception 'A FAIL (migrated): the edit did not publish a NEW version (active is still %)', v_ver_b;
    end if;
    select customer_name || '/' || cost_points into v_txt from public.loyalty_reward_versions
     where reward_id = v_reward_free and config_version_id = v_cfg;
    if v_txt is distinct from 'Free Coffee/3' then
      raise exception 'A FAIL (migrated): the open card''s version row was rewritten to % — THE P0', v_txt;
    end if;
    select customer_name || '/' || cost_points into v_txt from public.loyalty_reward_versions
     where reward_id = v_reward_free and config_version_id = v_ver_b;
    if v_txt is distinct from 'Espresso Shot/4' then
      raise exception 'A FAIL (migrated): the new version does not carry the edit (got %)', v_txt;
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_json := public.customer_get_stamp_card_v323('v433-scratch-kopi');
    execute 'reset role';
    select value->>'name' || '/' || (value->>'slot') || '/' || (value->>'availability') into v_txt
      from jsonb_array_elements(v_json->'milestones') where value->>'reward_id' = v_reward_free::text;
    if v_txt is distinct from 'Free Coffee/3/available_at_counter' then
      raise exception 'A FAIL (migrated): the customer''s open card shows % — the edit leaked onto the card', v_txt;
    end if;
    raise notice 'A ok (migrated): the edit version-forwarded; the customer''s card still says Free Coffee @3';
  else
    -- The defect class both pre-v423 (inert live-row-only edit) and v423+ (in-place rewrite of
    -- the published version, the live P0) share: the edit does NOT version-forward. Which shape
    -- this snapshot carries depends on the baseline watermark; both are wrong the same way.
    select active_config_version_id into v_uuid from public.businesses where id = v_biz;
    if v_uuid is distinct from v_cfg then
      raise exception 'A FAIL (baseline): expected NO version-forward before v433, but a new version was published (%)', v_uuid;
    end if;
    select customer_name || '/' || cost_points into v_txt from public.loyalty_reward_versions
     where reward_id = v_reward_free and config_version_id = v_cfg;
    if v_txt not in ('Espresso Shot/4', 'Free Coffee/3') then
      raise exception 'A FAIL (baseline): unexpected version-row state %', v_txt;
    end if;
    v_ver_b := v_cfg;
    raise notice 'A ok (baseline): DEFECT CLASS REPRODUCED — no version-forward (row reads %)', v_txt;
  end if;
  insert into _ctx values ('ver_b', v_ver_b::text)
  on conflict (k) do update set v = excluded.v;
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE B — A TWO-PART EDIT PENDS, THEN PUBLISHES (owner test B)
-- ============================================================================================
begin;
do $$
declare
  v433 boolean := position('stamp_config_edit_begin_v433' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='business_update_reward_v326'), '')) > 0;
  v_biz uuid := (select v from _ctx where k='biz');
  v_cfg uuid := (select v from _ctx where k='cfg');
  v_ver_b uuid := (select v from _ctx where k='ver_b');
  v_owner uuid := (select v from _ctx where k='owner');
  v_reward_big uuid := (select v from _ctx where k='reward_big');
  v_res jsonb; v_uuid uuid; v_n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_res := public.business_set_stamp_card_length_v414(v_biz, 6);
  if v433 then
    if v_res->>'publish_status' is distinct from 'pending'
       or position('stamp_final_gift_missing' in coalesce((v_res->'blockers')::text, '')) = 0 then
      raise exception 'B FAIL (migrated): lengthening without a final gift should PEND with stamp_final_gift_missing, got %', v_res;
    end if;
    select active_config_version_id into v_uuid from public.businesses where id = v_biz;
    if v_uuid is distinct from v_ver_b then
      raise exception 'B FAIL (migrated): a pending edit changed the ACTIVE version (% -> %)', v_ver_b, v_uuid;
    end if;
    -- Second half: the final gift moves to stamp 6 — the SAME pending draft publishes.
    v_res := public.business_update_reward_v326(v_biz, v_reward_big, 'Big Gift', 6, null, 0, null, false);
    if v_res->>'publish_status' is distinct from 'published' then
      raise exception 'B FAIL (migrated): moving the final gift to stamp 6 did not publish the pending draft: %', v_res;
    end if;
    select active_config_version_id into v_uuid from public.businesses where id = v_biz;
    if v_uuid = v_ver_b or v_uuid = v_cfg then
      raise exception 'B FAIL (migrated): the completed pair did not publish a new version (active %)', v_uuid;
    end if;
    select stamp_target into v_n from public.loyalty_program_versions
     where config_version_id = v_uuid and business_id = v_biz;
    if v_n is distinct from 6 then
      raise exception 'B FAIL (migrated): the published version''s stamp_target is % (expected 6)', v_n;
    end if;
    select stamp_target into v_n from public.loyalty_program_versions
     where config_version_id = v_cfg and business_id = v_biz;
    if v_n is distinct from 5 then
      raise exception 'B FAIL (migrated): the OPEN card''s version had its length rewritten to %', v_n;
    end if;
    select cost_points into v_n from public.loyalty_reward_versions
     where reward_id = v_reward_big and config_version_id = v_cfg;
    if v_n is distinct from 5 then
      raise exception 'B FAIL (migrated): the OPEN card''s final gift moved to slot %', v_n;
    end if;
    update _ctx set v = v_uuid::text where k = 'ver_b'; -- the latest setup: 6 slots, Espresso @4, Big @6
    raise notice 'B ok (migrated): length+gift pended then published as one version; the open card keeps 5 slots with its gift at 5';
  else
    select stamp_target into v_n from public.loyalty_program_versions
     where config_version_id = v_cfg and business_id = v_biz;
    if v_n is distinct from 5 then
      raise exception 'B FAIL (baseline): expected the INERT defect (version row still 5 while the live row says 6), got %', v_n;
    end if;
    raise notice 'B ok (baseline): DEFECT REPRODUCED — the length edit wrote only the live row (engine-inert)';
  end if;
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE C1 — EARN-RATE CHANGE 500 → 600 (its own publish instant)
-- ============================================================================================
begin;
do $$
declare
  v_biz uuid := (select v from _ctx where k='biz');
  v_owner uuid := (select v from _ctx where k='owner');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform public.business_set_earning_rule_v359(v_biz, null, 600, null, null);
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE C2 — THE PINNED SALE, COMPLETION, AND THE FRESH CARD (owner test C)
-- ============================================================================================
begin;
do $$
declare
  v433 boolean := position('stamp_config_edit_begin_v433' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='business_update_reward_v326'), '')) > 0;
  v436 boolean := position('stamp_expire_open_cycle_v435' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app' and p.proname='on_sale_recorded'), '')) > 0;
  v_biz uuid := (select v from _ctx where k='biz');
  v_owner uuid := (select v from _ctx where k='owner');
  v_cust uuid := (select v from _ctx where k='cust');
  v_client uuid := (select v from _ctx where k='client');
  v_spine_stamps uuid := (select v from _ctx where k='spine_stamps');
  v_reward_free uuid := (select v from _ctx where k='reward_free');
  v_reward_big uuid := (select v from _ctx where k='reward_big');
  v_branch uuid := (select v from _ctx where k='branch');
  v_json jsonb; v_txt text; v_pts integer; v_n integer; v_sale uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_client, 'service', 1500, v_branch) returning id into v_sale;
  select points into v_pts from public.points_ledger
   where sale_id = v_sale and entry_type = 'earn' and programme_id = v_spine_stamps;
  if v_pts is distinct from 3 then
    raise exception 'C FAIL: a S$15 sale on a card started at S$5/stamp earned % stamps (expected 3 — rule 6)', v_pts;
  end if;
  raise notice 'C ok: S$15 earned +3 at the card''s own S$5 rate (filled now 7 of 5)';

  perform app.redeem_reward_core(v_biz, v_client, v_reward_big, 'v433-final-claim-0001', v_branch, null, null);
  select count(*) into v_n from public.stamp_cycles
   where business_id = v_biz and client_id = v_client and origin = 'claimed' and slots = 5;
  if v_n <> 1 then
    raise exception 'C FAIL: the final claim did not close the 5-slot card (% closed cycles)', v_n;
  end if;

  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_client, 'service', 3000, v_branch) returning id into v_sale;
  select points into v_pts from public.points_ledger
   where sale_id = v_sale and entry_type = 'earn' and programme_id = v_spine_stamps;
  if v436 then
    if v_pts is distinct from 5 then
      raise exception 'C FAIL (migrated): a S$30 sale on the NEW card earned % (expected 5 at the latest S$6 rate)', v_pts;
    end if;
    raise notice 'C ok (migrated): the fresh card earns at the LATEST rate (S$30 → +5 at S$6)';
  else
    if v_pts is distinct from 6 then
      raise exception 'C FAIL (baseline): expected the INERT defect (live row says S$6, engine still pays S$5 → +6), got +%', v_pts;
    end if;
    raise notice 'C ok (baseline): DEFECT REPRODUCED — the rate change never reached the engine (+6 at the old rate)';
  end if;

  if v433 then
    perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_json := public.customer_get_stamp_card_v323('v433-scratch-kopi');
    execute 'reset role';
    select value->>'name' || '/' || (value->>'slot') into v_txt
      from jsonb_array_elements(v_json->'milestones') where value->>'reward_id' = v_reward_free::text;
    if (v_json->>'slots')::integer is distinct from 6 or v_txt is distinct from 'Espresso Shot/4' then
      raise exception 'C FAIL (migrated): after completion the next card shows slots=% milestone=% (expected 6 and Espresso Shot/4)', v_json->>'slots', v_txt;
    end if;
    raise notice 'C ok (migrated): completion moved the customer straight onto the latest setup (6 slots, Espresso Shot @4)';
  end if;
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE D — EXPIRY + SURVIVAL (owner test D, rules 4/5/7) — v435 machinery only
-- ============================================================================================
begin;
do $$
declare
  v435 boolean := position('nestly_v435' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app' and p.proname='redeem_reward_core'), '')) > 0;
  v_biz uuid := (select v from _ctx where k='biz');
  v_owner uuid := (select v from _ctx where k='owner');
  v_client2 uuid := (select v from _ctx where k='client2');
  v_spine_stamps uuid := (select v from _ctx where k='spine_stamps');
  v_reward_free uuid := (select v from _ctx where k='reward_free');
  v_reward_big uuid := (select v from _ctx where k='reward_big');
  v_branch uuid := (select v from _ctx where k='branch');
  v_json jsonb; v_txt text; v_pts integer; v_n integer; v_uuid uuid; v_expired_cfg uuid;
  v_d record; v_sale uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  if not v435 then
    if to_regprocedure('app.run_stamp_expiry()') is not null then
      raise exception 'D FAIL (baseline): stamp expiry machinery exists before v435';
    end if;
    raise notice 'D ok (baseline): no stamp expiry machinery exists — a 40-day-old card would never lapse (the gap v435 closes)';
    return;
  end if;

  -- Validity 30 days → a new version carries it (client 1 earned since the last publish → split).
  perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, 30);
  select active_config_version_id into v_uuid from public.businesses where id = v_biz;
  select stamp_validity_days into v_n from public.loyalty_program_versions
   where config_version_id = v_uuid and business_id = v_biz;
  if v_n is distinct from 30 then
    raise exception 'D FAIL: the active version does not carry validity 30 (got %)', v_n;
  end if;

  -- Client 2's card started 40 days ago (backdated first stamp). Every published version is
  -- newer than that, so the v416 pin falls back to the ACTIVE version — validity 30 → overdue.
  declare v_seed uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_insert_id', v_seed::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id, created_at)
    values (v_seed, v_biz, v_client2, 'adjust', 4, 'v435 backdated card', v_owner, v_spine_stamps, now() - interval '40 days');
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining, earned_at)
  values (v_biz, v_client2, v_spine_stamps, 4, 4, now() - interval '40 days');

  select * into v_d from app.stamp_cycle_deadline_v435(v_biz, v_client2, v_spine_stamps);
  if v_d.expires_at is null or v_d.expires_at > now() then
    raise exception 'D FAIL: a 40-day-old card with 30-day validity is not overdue (expires_at %)', v_d.expires_at;
  end if;

  select app.run_stamp_expiry_for_business(v_biz) into v_n;
  if v_n <> 1 then
    raise exception 'D FAIL: the sweep closed % cards (expected exactly 1 — client 1''s card has no validity pin)', v_n;
  end if;
  select config_version_id into v_expired_cfg from public.stamp_cycles
   where business_id = v_biz and client_id = v_client2 and origin = 'expired' and slots = 4;
  if v_expired_cfg is null then
    raise exception 'D FAIL: no expired cycle with slots=4 was recorded for client 2';
  end if;

  -- Rule 7: programme OFF — the earned milestone must still be listed and claimable.
  update public.business_programmes set active = false where id = v_spine_stamps;
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client2, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'available_at_counter' then
    raise exception 'D FAIL: with the programme OFF, the earned milestone reads % (expected available_at_counter — rule 7)', v_txt;
  end if;
  if exists (select 1 from app.reward_availability_v432(v_biz, v_client2, now()) core
              where core.reward_id = v_reward_big) then
    raise exception 'D FAIL: with the programme OFF, the UNEARNED final gift is still listed';
  end if;

  v_json := app.redeem_reward_core(v_biz, v_client2, v_reward_free, 'v435-survival-claim-01', v_branch, null, null)::jsonb;
  if not coalesce((v_json->>'from_expired_card')::boolean, false)
     or coalesce((v_json->>'stamp_card_closed')::boolean, true) then
    raise exception 'D FAIL: the survival claim did not run as a survival claim: %', v_json;
  end if;
  raise notice 'D ok: earned milestone claimed FROM THE EXPIRED CARD while the programme was OFF';

  update public.business_programmes set active = true where id = v_spine_stamps;

  -- The unearned final gift lapsed with the card.
  begin
    perform app.redeem_reward_core(v_biz, v_client2, v_reward_big, 'v435-lapsed-claim-01', v_branch, null, null);
    raise exception 'D FAIL: the UNEARNED final gift was claimable after expiry';
  exception when check_violation then null; -- 'not enough stamps yet' — correct
  end;
  -- One claim per expired cycle per reward: the survival scan skips already-claimed cycles, so
  -- a second attempt falls through to the (empty) current card and is refused there.
  begin
    perform app.redeem_reward_core(v_biz, v_client2, v_reward_free, 'v435-survival-claim-02', v_branch, null, null);
    raise exception 'D FAIL: the survival milestone was claimable TWICE';
  exception when check_violation or unique_violation then null;
  end;

  -- Rule 5: the next qualifying earn starts a fresh card on the latest setup, with its clock.
  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_client2, 'service', 1200, v_branch) returning id into v_sale;
  select points into v_pts from public.points_ledger
   where sale_id = v_sale and entry_type = 'earn' and programme_id = v_spine_stamps;
  if v_pts is distinct from 2 then
    raise exception 'D FAIL: the fresh card earned % on S$12 (expected 2 at the latest S$6 rate)', v_pts;
  end if;
  select * into v_d from app.stamp_cycle_deadline_v435(v_biz, v_client2, v_spine_stamps);
  if v_d.expires_at is null or v_d.expires_at <= now() or v_d.validity_days is distinct from 30
     or v_d.filled is distinct from 2 then
    raise exception 'D FAIL: the fresh card''s clock is wrong (filled %, validity %, expires %)', v_d.filled, v_d.validity_days, v_d.expires_at;
  end if;
  raise notice 'D ok: expiry closed the card as history, survivors stayed claimable exactly once, the next earn started a fresh 30-day card on the latest setup';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE E — POINTS RULE CHANGES ARE NOT RETROACTIVE (owner test E, rules 8/9)
-- ============================================================================================
begin;
do $$
declare
  v_owner uuid := (select v from _ctx where k='owner');
  v_pbiz uuid := gen_random_uuid();
  v_ppot uuid; v_pclient uuid := gen_random_uuid(); v_pbatch uuid := gen_random_uuid();
  v_pexp timestamptz := now() + interval '30 days';
  v_n integer;
begin
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_pbiz, 'V435 Points Firm', 'v435-points-firm', array['loyalty'], 'redeem');
  select id into v_ppot from public.business_programmes
   where business_id = v_pbiz and kind = 'points';
  insert into public.staff(business_id, user_id, role, active) values (v_pbiz, v_owner, 'owner', true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v435 E fixture', updated_at=clock_timestamp()
   where business_id=v_pbiz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_pbiz, false) on conflict (business_id) do update set workspace_paused=false;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind, configuration_status,
                                      earn_points_per_dollar, expiry_mode, expiry_days)
  values (v_pbiz, true, 'classic', 'points', 'published', 1, 'fixed', 30)
  on conflict (business_id) do update
    set active=true, loyalty_model='classic', kind='points', expiry_mode='fixed', expiry_days=30;
  insert into public.clients(id, business_id, full_name, phone)
  values (v_pclient, v_pbiz, 'V435 Points Customer', '+65 9435 0001');
  perform app.acquire_loyalty_exclusive_v480(v_pbiz);
  insert into public.points_batches(id, business_id, client_id, programme_id, earned, remaining, expires_at)
  values (v_pbatch, v_pbiz, v_pclient, v_ppot, 100, 100, v_pexp);

  perform public.business_set_earning_rule_v359(v_pbiz, null, null, 'fixed', 60);
  select expiry_days into v_n from public.loyalty_programs where business_id = v_pbiz;
  if v_n is distinct from 60 then
    raise exception 'E FAIL: the expiry rule change did not save (expiry_days %)', v_n;
  end if;
  if (select expires_at from public.points_batches where id = v_pbatch) is distinct from v_pexp then
    raise exception 'E FAIL: the rule change REWROTE an existing batch''s expiry — rule 8/9 broken';
  end if;
  raise notice 'E ok: the expiry rule change saved and no existing batch was touched (identical before and after the wave)';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE F — THE WIZARD SWITCH PATH (owner test F / rule 12): a draft DECLARING points
-- publishes while stamps still runs, and its gifts bind to the declared programme
-- ============================================================================================
begin;
do $$
declare
  v434 boolean := position('nestly_v434' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='save_loyalty_reward_draft'), '')) > 0;
  v_biz uuid := (select v from _ctx where k='biz');
  v_owner uuid := (select v from _ctx where k='owner');
  v_spine_stamps uuid := (select v from _ctx where k='spine_stamps');
  v_spine_points uuid := (select v from _ctx where k='spine_points');
  v_res jsonb; v_uuid uuid; v_draft uuid; v_pgift uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_draft := ((public.create_loyalty_config_draft(v_biz, null, 'v434 acceptance'))::jsonb ->> 'version_id')::uuid;
  update public.loyalty_program_versions
     set loyalty_model = 'classic', kind = 'points'
   where config_version_id = v_draft and business_id = v_biz;
  v_pgift := ((public.save_loyalty_reward_draft(v_draft, null, jsonb_build_object(
      'internal_name', 'Points Ten Gift', 'customer_name', 'Points Ten Gift',
      'cost_points', 10, 'fulfillment_kind', 'manual_item', 'credit_cents', 0)))::jsonb ->> 'reward_id')::uuid;
  select programme_id into v_uuid from public.loyalty_reward_versions
   where reward_id = v_pgift and config_version_id = v_draft;

  if v434 then
    if v_uuid is distinct from v_spine_points then
      raise exception 'F FAIL (migrated): a gift saved into a POINTS-declared draft was bound to programme % (expected the points spine %)', v_uuid, v_spine_points;
    end if;
    v_res := (public.publish_loyalty_config(v_draft))::jsonb;
    if v_res->>'status' is distinct from 'published' then
      raise exception 'F FAIL (migrated): the points-declared draft did not publish: %', v_res;
    end if;
    raise notice 'F ok (migrated): the wizard''s switch draft publishes on its OWN declaration — gift bound to points, no stamps guard misfire';
  else
    if v_uuid is distinct from v_spine_stamps then
      raise exception 'F FAIL (baseline): expected the DEFECT (draft gift auto-tagged to the RUNNING stamps spine), got %', v_uuid;
    end if;
    begin
      perform public.publish_loyalty_config(v_draft);
      raise exception 'F FAIL (baseline): the mis-tagged draft published — expected the ''past the last stamp'' refusal';
    exception when check_violation then null; -- 'a stamp gift sits past the last stamp on the card'
    end;
    raise notice 'F ok (baseline): DEFECT REPRODUCED — the wizard gift was tagged to the running spine and the publish was refused';
  end if;
end $$;
commit;

-- ============================================================================================
-- PHASE G — HISTORY ROWS KEEP THEIR UNIT (owner rule 13 / v437)
-- ============================================================================================
begin;
do $$
declare
  v437 boolean := position('loyalty_unit' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='customer_get_transaction_history_v81'), '')) > 0;
  v_cust uuid := (select v from _ctx where k='cust');
  v_json jsonb; v_row jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_json := public.customer_get_transaction_history_v167('v433-scratch-kopi', '{}'::jsonb);
  execute 'reset role';
  -- The standalone seed adjustment lives in the STAMPS pot (phase 0). After phase F the active
  -- configuration declares points — exactly the state that used to relabel this row.
  select value into v_row from jsonb_array_elements(v_json->'items')
   where value->>'source_kind'='points_ledger' and value->>'event_type'='points_adjust'
   order by value->>'event_at' limit 1;
  if v_row is null then
    raise exception 'G FAIL: the seed adjustment row is missing from the customer history';
  end if;
  if v437 then
    if v_row->>'loyalty_unit' is distinct from 'stamps'
       or v_row->>'description' is distinct from 'Stamps adjustment' then
      raise exception 'G FAIL (migrated): the stamps-pot row reads unit=% description=% (expected stamps / Stamps adjustment)',
        v_row->>'loyalty_unit', v_row->>'description';
    end if;
    if not exists (select 1 from jsonb_array_elements(v_json->'items')
                    where value->>'source_kind'='sale' and value->>'loyalty_unit'='stamps'
                      and (value->>'points_earned')::integer > 0) then
      raise exception 'G FAIL (migrated): no sale row carries its stamps unit';
    end if;
    raise notice 'G ok (migrated): history rows keep the unit they happened in (rule 13)';
  else
    if v_row ? 'loyalty_unit' then
      raise exception 'G FAIL (baseline): loyalty_unit exists before v437';
    end if;
    if v_row->>'description' is distinct from 'Points adjustment' then
      raise exception 'G FAIL (baseline): expected the DEFECT (a stamps-pot row labelled "Points adjustment"), got %', v_row->>'description';
    end if;
    raise notice 'G ok (baseline): DEFECT REPRODUCED — a stamps-pot row is labelled in points vocabulary';
  end if;
end $$;
commit;

select 'v433–v437 executed acceptance finished (see notices)' as result;
