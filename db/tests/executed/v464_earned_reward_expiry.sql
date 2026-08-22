-- EXECUTED acceptance for nestly_v464 — owner-set expiry on EARNED stamp rewards (ruling R3(e),
-- 2026-08-23), exercised end to end through the real RPCs, the real trigger and the real sweep.
--
--   A  no setting  → an earned reward never expires (today's behaviour, unchanged)
--   B  set N       → the NEW version carries it; a card already open keeps its own version and
--                    its rewards keep having no deadline at all (never retroactive)
--   C  a card started under the setting gives its earned rewards a real date, the customer and
--      the counter read the SAME date, and an overdue one is withdrawn from both BEFORE any
--      sweep runs (the v432 one-availability-core invariant)
--   D  the sweep withdraws exactly the overdue ones, once, with a history entry the customer can
--      see and an audit trail the owner can see
--   E  card expiry x reward expiry: a reward with NO deadline still survives its card lapsing
--      (protected v435 rule 4/5), and a reward WITH one dies on its own date whatever its card
--      is doing
--   F  negative controls: the unearned milestone is never withdrawn, the sweep is idempotent, an
--      out-of-range setting is refused, and a reward already recorded expired stays expired
--
--   psql -v ON_ERROR_STOP=1 -f db/tests/executed/v464_earned_reward_expiry.sql
--
-- Dual-mode. BASELINE pins the gap: no expiry machinery exists, so an owner cannot give a reward
-- a shelf life at all. MIGRATED pins the rule.
--
-- HARNESS: PHASED-COMMITS (the v433 structure, for the v433 reason). now() is transaction-fixed
-- and everything here is time-ordered — the version pin, the earn moment, the deadline. One
-- transaction would collapse them onto a single instant.
--
-- THE TIME MACHINE. A 60-day-old stamp card cannot be produced by a test that runs in one second,
-- so two fixture-only devices are used and are marked at every use:
--   (1) points_ledger rows inserted with an explicit backdated created_at — the recipe v435's own
--       acceptance suite uses;
--   (2) ONE update of firm_config_versions.published_at, so a backdated card can pin to a version
--       that carries the setting. Nothing in the engine writes published_at except the publish
--       itself, and this scratch tenant lives in its own throwaway database.

create temp table _ctx(k text primary key, v text);

-- ============================================================================================
-- PHASE 0 — scratch tenant: a 5-stamp card with gifts at 3 and 5, two linked customers.
-- ============================================================================================
begin;
do $$
declare
  v_biz uuid := gen_random_uuid();
  v_cfg uuid;
  v_spine_stamps uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_cust_a uuid := gen_random_uuid();
  v_cust_b uuid := gen_random_uuid();
  v_client1 uuid := gen_random_uuid();
  v_client2 uuid := gen_random_uuid();
  v_client3 uuid := gen_random_uuid();
  v_client4 uuid := gen_random_uuid();
  v_reward_free uuid := gen_random_uuid();
  v_reward_big uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_n integer;
begin
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V464 Scratch Kopi', 'v464-scratch-kopi', array['loyalty'], 'redeem');
  insert into public.business_programmes(id, business_id, kind, active, sort)
  values (v_spine_stamps, v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true
  returning id into v_spine_stamps;
  update public.business_programmes set active = false
   where business_id = v_biz and kind = 'points';

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v464-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust_a,'authenticated','authenticated',
    'zz-v464-cust-a-'||substr(v_cust_a::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust_b,'authenticated','authenticated',
    'zz-v464-cust-b-'||substr(v_cust_b::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V464 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v464 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused=false;
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;

  -- The c45 write guards fire on the fixture's own loyalty writes (v431 lesson).
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
    select v_cfg, v_biz, coalesce(max(version_no), 0) + 1, 'published', md5('v464-published'), now()
      from public.firm_config_versions where business_id = v_biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client1, v_biz, 'V464 Customer One',   '+65 9464 0001'),
         (v_client2, v_biz, 'V464 Customer Two',   '+65 9464 0002'),
         (v_client3, v_biz, 'V464 Customer Three', '+65 9464 0003'),
         (v_client4, v_biz, 'V464 Customer Four',  '+65 9464 0004');

  declare v_id_a uuid := gen_random_uuid(); v_id_b uuid := gen_random_uuid();
          v_link_a uuid := gen_random_uuid(); v_link_b uuid := gen_random_uuid();
  begin
    insert into public.customer_identities(id, auth_user_id, status)
    values (v_id_a, v_cust_a, 'active'), (v_id_b, v_cust_b, 'active');
    perform set_config('app.customer_link_insert_id', v_link_a::text, true);
    insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link_a, v_biz, v_id_a, v_cust_a, v_client1, 'verified', 'phone_claim', now());
    perform set_config('app.customer_link_insert_id', v_link_b::text, true);
    insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link_b, v_biz, v_id_b, v_cust_b, v_client2, 'verified', 'phone_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);
  end;

  -- The two gifts on the card.
  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values
    (v_reward_free, v_biz, 'Free Kopi', 'Free Kopi', 'Free Kopi', 'manual_item', 3, 0, 0, true, false, 1, v_spine_stamps),
    (v_reward_big,  v_biz, 'Big Gift',  'Big Gift',  'Big Gift',  'manual_item', 5, 0, 0, true, false, 2, v_spine_stamps);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, description, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, image_ref, sort, programme_id)
  values
    (v_reward_free, v_biz, v_cfg, 'Free Kopi', 'Free Kopi', 'On the card', 'manual_item', 3, 0, 0, null, 1, v_spine_stamps),
    (v_reward_big,  v_biz, v_cfg, 'Big Gift',  'Big Gift',  'On the card', 'manual_item', 5, 0, 0, null, 2, v_spine_stamps);

  -- Client 1's card: 4 stamps NOW, under version 1 (which sets no reward expiry). This card is
  -- the non-retroactivity control and is never touched again.
  declare v_seed uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_insert_id', v_seed::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id)
    values (v_seed, v_biz, v_client1, 'adjust', 4, 'v464 seed stamps', v_owner, v_spine_stamps);
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining)
  values (v_biz, v_client1, v_spine_stamps, 4, 4);

  select filled into v_n from app.stamp_progress_v323(v_biz, v_client1);
  if v_n is distinct from 4 then
    raise exception 'FIXTURE BROKEN: client 1 holds % stamps (expected 4)', v_n;
  end if;

  insert into _ctx(k, v) values
    ('biz', v_biz::text), ('cfg1', v_cfg::text), ('owner', v_owner::text),
    ('cust_a', v_cust_a::text), ('cust_b', v_cust_b::text),
    ('client1', v_client1::text), ('client2', v_client2::text),
    ('client3', v_client3::text), ('client4', v_client4::text),
    ('spine_stamps', v_spine_stamps::text), ('branch', v_branch::text),
    ('reward_free', v_reward_free::text), ('reward_big', v_reward_big::text);
  raise notice '0 ok: V464 Scratch Kopi — 5-stamp card, gifts at 3 and 5, client 1 holding 4 stamps';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE A — NO SETTING, NO DEADLINE (today's behaviour, and the baseline arm)
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_cust_a uuid := (select v from _ctx where k='cust_a')::uuid;
  v_client1 uuid := (select v from _ctx where k='client1')::uuid;
  v_spine uuid := (select v from _ctx where k='spine_stamps')::uuid;
  v_reward_free uuid := (select v from _ctx where k='reward_free')::uuid;
  v_row record; v_txt text; v_json jsonb; v_at timestamptz;
begin
  if not v464 then
    -- BASELINE: prove the gap rather than assert against machinery that does not exist.
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='loyalty_program_versions'
                  and column_name='stamp_reward_expiry_days') then
      raise exception 'A FAIL (baseline): the reward-expiry column exists before v464';
    end if;
    if to_regprocedure('app.run_stamp_reward_expiry()') is not null then
      raise exception 'A FAIL (baseline): the reward-expiry sweep exists before v464';
    end if;
    raise notice 'A ok (baseline): an owner has no way to give an earned reward a shelf life — the gap v464 closes';
    return;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- The one calculation says: earned, but no deadline.
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client1, v_spine, 0, 3);
  if v_row.earned_at is null then
    raise exception 'A FAIL: the 3-stamp gift on a 4-stamp card has no earned_at';
  end if;
  if v_row.expiry_days is not null or v_row.expires_at is not null then
    raise exception 'A FAIL: an unset programme produced a deadline (days %, at %)', v_row.expiry_days, v_row.expires_at;
  end if;

  -- The availability core offers it, with a null date.
  select core.availability, core.reward_expires_at into v_txt, v_at
    from app.reward_availability_v432(v_biz, v_client1, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'available_at_counter' or v_at is not null then
    raise exception 'A FAIL: an earned gift with no deadline reads % / %', v_txt, v_at;
  end if;

  -- And the customer's own card agrees.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_json := public.customer_get_stamp_card_v323('v464-scratch-kopi');
  execute 'reset role';
  select value into v_json from jsonb_array_elements(v_json -> 'milestones') as t(value)
   where (value ->> 'slot')::integer = 3;
  if v_json ->> 'availability' is distinct from 'available_at_counter'
     or v_json ->> 'expires_at' is not null then
    raise exception 'A FAIL: the customer''s card shows % / expires_at % for a gift with no deadline',
      v_json ->> 'availability', v_json ->> 'expires_at';
  end if;
  raise notice 'A ok: with no setting, an earned reward carries no deadline and stays claimable — unchanged';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE B — SET 30 DAYS: the NEW version carries it; the OPEN card does not (never retroactive)
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_cfg1 uuid := (select v from _ctx where k='cfg1')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_client1 uuid := (select v from _ctx where k='client1')::uuid;
  v_spine uuid := (select v from _ctx where k='spine_stamps')::uuid;
  v_cfg2 uuid; v_n integer; v_row record; v_save jsonb;
begin
  if not v464 then raise notice 'B skipped (baseline)'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- Out of range is refused before anything is written (negative control F1).
  begin
    perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 4000);
    raise exception 'B FAIL: a 4000-day reward expiry was accepted';
  exception when sqlstate '22023' then null;
  end;

  v_save := public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 30);
  if v_save ->> 'publish_status' <> 'published' then
    raise exception 'B FAIL: the save did not publish (%)', v_save;
  end if;
  if (v_save ->> 'stamp_reward_expiry_days')::integer is distinct from 30 then
    raise exception 'B FAIL: the save returned reward expiry % ', v_save ->> 'stamp_reward_expiry_days';
  end if;

  select active_config_version_id into v_cfg2 from public.businesses where id = v_biz;
  if v_cfg2 = v_cfg1 then
    raise exception 'B FAIL: the edit was written IN PLACE — the v433 split did not happen';
  end if;
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg2 and business_id = v_biz;
  if v_n is distinct from 30 then
    raise exception 'B FAIL: the new version carries reward expiry % (expected 30)', v_n;
  end if;
  -- The version the customer's card is pinned to was NOT rewritten.
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg1 and business_id = v_biz;
  if v_n is not null then
    raise exception 'B FAIL: version 1 was mutated to reward expiry % — the pin is worthless', v_n;
  end if;
  -- publish_loyalty_config carried it onto the display mirror.
  select stamp_reward_expiry_days into v_n from public.loyalty_programs where business_id = v_biz;
  if v_n is distinct from 30 then
    raise exception 'B FAIL: the live mirror carries reward expiry % (expected 30)', v_n;
  end if;

  -- THE RULING'S CORE PROMISE: nothing the customer already holds changed.
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client1, v_spine, 0, 3);
  if v_row.expires_at is not null then
    raise exception 'B FAIL: a reward earned BEFORE the setting now expires at % — retroactive', v_row.expires_at;
  end if;
  if app.stamp_cycle_version_v416(v_biz, v_client1, v_spine) <> v_cfg1 then
    raise exception 'B FAIL: client 1''s open card moved off the version it started under';
  end if;
  insert into _ctx(k, v) values ('cfg2', v_cfg2::text);
  raise notice 'B ok: 30 days written to a NEW version; the open card keeps version 1 and its rewards keep no deadline';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE C — A CARD STARTED UNDER THE SETTING. One future deadline, one already overdue, and the
--           customer, the counter and the till reading the same answer BEFORE any sweep.
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_cfg2 uuid := (select v from _ctx where k='cfg2')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_cust_b uuid := (select v from _ctx where k='cust_b')::uuid;
  v_client2 uuid := (select v from _ctx where k='client2')::uuid;
  v_client3 uuid := (select v from _ctx where k='client3')::uuid;
  v_spine uuid := (select v from _ctx where k='spine_stamps')::uuid;
  v_branch uuid := (select v from _ctx where k='branch')::uuid;
  v_reward_free uuid := (select v from _ctx where k='reward_free')::uuid;
  v_row record; v_json jsonb; v_txt text; v_staff jsonb; v_n integer; v_at timestamptz;
begin
  if not v464 then raise notice 'C skipped (baseline)'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- TIME MACHINE (2): version 2 is moved back 100 days so a backdated card can pin to it. Version
  -- 1 keeps today's published_at, so client 1's card — started today — still pins to version 1 and
  -- remains the control.
  update public.firm_config_versions set published_at = now() - interval '100 days'
   where id = v_cfg2 and business_id = v_biz;

  -- TIME MACHINE (1): two backdated cards, both pinning to version 2 (30-day reward expiry).
  --   client 3: first stamp 20 days ago  → the 3-stamp gift expires in 10 days  (still valid)
  --   client 2: first stamp 60 days ago  → it expired 30 days ago                (overdue)
  declare v_s3 uuid := gen_random_uuid(); v_s2 uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    perform set_config('app.points_ledger_insert_id', v_s3::text, true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id, created_at)
    values (v_s3, v_biz, v_client3, 'adjust', 4, 'v464 backdated card (20d)', v_owner, v_spine, now() - interval '20 days');
    perform set_config('app.points_ledger_insert_id', v_s2::text, true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id, created_at)
    values (v_s2, v_biz, v_client2, 'adjust', 4, 'v464 backdated card (60d)', v_owner, v_spine, now() - interval '60 days');
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining, earned_at)
  values (v_biz, v_client3, v_spine, 4, 4, now() - interval '20 days'),
         (v_biz, v_client2, v_spine, 4, 4, now() - interval '60 days');

  if app.stamp_cycle_version_v416(v_biz, v_client2, v_spine) <> v_cfg2
     or app.stamp_cycle_version_v416(v_biz, v_client3, v_spine) <> v_cfg2 then
    raise exception 'C FAIL (fixture): the backdated cards did not pin to version 2';
  end if;

  -- C1  the still-valid one: a real date, in the future, and the reward is claimable.
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client3, v_spine, 0, 3);
  if v_row.expiry_days is distinct from 30 or v_row.expires_at is null or v_row.expires_at <= now() then
    raise exception 'C1 FAIL: client 3''s gift reads days % / expires % (expected 30 / ~10 days out)',
      v_row.expiry_days, v_row.expires_at;
  end if;
  if v_row.expires_at > now() + interval '11 days' then
    raise exception 'C1 FAIL: client 3''s deadline is % — measured from the wrong moment', v_row.expires_at;
  end if;
  select core.availability, core.reward_expires_at into v_txt, v_at
    from app.reward_availability_v432(v_biz, v_client3, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'available_at_counter' or v_at is null then
    raise exception 'C1 FAIL: a reward inside its deadline reads % / %', v_txt, v_at;
  end if;

  -- C2  the overdue one is withdrawn by the READ PATH, before any sweep has run.
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client2, v_spine, 0, 3);
  if v_row.expires_at is null or v_row.expires_at > now() then
    raise exception 'C2 FAIL (fixture): client 2''s deadline is % — not overdue', v_row.expires_at;
  end if;
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client2, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'reward_expired' then
    raise exception 'C2 FAIL: an overdue reward reads % (expected reward_expired) with no sweep run', v_txt;
  end if;
  if exists (select 1 from public.stamp_reward_expiries_v464
              where business_id = v_biz and client_id = v_client2) then
    raise exception 'C2 FAIL (fixture): a history row exists before the sweep ran';
  end if;

  -- C3  THE v432 INVARIANT: the till offers exactly what the customer can claim. Client 2's gift
  --     is not on the staff list at all; client 3's is, carrying its date.
  execute 'set local role authenticated';
  v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client2, null);
  execute 'reset role';
  if exists (select 1 from jsonb_array_elements(v_staff -> 'rewards') as t(value)
              where value ->> 'reward_id' = v_reward_free::text) then
    raise exception 'C3 FAIL: the till still offers a reward the customer''s wallet has withdrawn: %',
      v_staff -> 'rewards';
  end if;
  execute 'set local role authenticated';
  v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client3, null);
  execute 'reset role';
  select value into v_json from jsonb_array_elements(v_staff -> 'rewards') as t(value)
   where value ->> 'reward_id' = v_reward_free::text;
  if v_json is null or (v_json ->> 'available_now')::boolean is not true then
    raise exception 'C3 FAIL: the till does not offer client 3''s still-valid reward: %', v_staff -> 'rewards';
  end if;
  if v_json ->> 'expires_at' is null then
    raise exception 'C3 FAIL: the till carries no expiry date for a reward that has one: %', v_json;
  end if;

  -- C4  the customer's own two surfaces carry the same date and the same verdict.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust_b, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_json := public.customer_get_stamp_card_v323('v464-scratch-kopi');
  v_staff := public.customer_get_reward_catalog('v464-scratch-kopi');
  execute 'reset role';
  select value into v_json from jsonb_array_elements(v_json -> 'milestones') as t(value)
   where (value ->> 'slot')::integer = 3;
  if v_json ->> 'availability' is distinct from 'reward_expired' or v_json ->> 'expires_at' is null then
    raise exception 'C4 FAIL: the customer''s card reads % / % for an overdue reward',
      v_json ->> 'availability', v_json ->> 'expires_at';
  end if;
  select value into v_json from jsonb_array_elements(v_staff -> 'rewards') as t(value)
   where value ->> 'customer_name' = 'Free Kopi';
  if v_json ->> 'availability' is distinct from 'reward_expired' or v_json ->> 'expires_at' is null then
    raise exception 'C4 FAIL: the customer''s catalogue reads % / % for an overdue reward',
      v_json ->> 'availability', v_json ->> 'expires_at';
  end if;

  -- C5  and the counter refuses it, in words a person can read.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    perform app.redeem_reward_core(v_biz, v_client2, v_reward_free, 'v464-expired-claim-01', v_branch, null, null);
    raise exception 'C5 FAIL: the counter honoured an expired reward';
  exception when check_violation then
    get stacked diagnostics v_txt = message_text;
    if position('expired' in lower(v_txt)) = 0 then
      raise exception 'C5 FAIL: the refusal does not say the reward expired: "%"', v_txt;
    end if;
  end;
  raise notice 'C ok: a valid reward shows its date everywhere; an overdue one is withdrawn from the wallet, the till and the counter alike, with no sweep — refusal: "%"', v_txt;
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE D — THE SWEEP: exactly the overdue ones, once, with a history entry
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_cust_b uuid := (select v from _ctx where k='cust_b')::uuid;
  v_client1 uuid := (select v from _ctx where k='client1')::uuid;
  v_client2 uuid := (select v from _ctx where k='client2')::uuid;
  v_client3 uuid := (select v from _ctx where k='client3')::uuid;
  v_reward_free uuid := (select v from _ctx where k='reward_free')::uuid;
  v_reward_big uuid := (select v from _ctx where k='reward_big')::uuid;
  v_n integer; v_json jsonb;
begin
  if not v464 then raise notice 'D skipped (baseline)'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select app.run_stamp_reward_expiry_for_business(v_biz) into v_n;
  if v_n <> 1 then
    raise exception 'D FAIL: the sweep withdrew % rewards (expected exactly 1 — client 2''s Free Kopi)', v_n;
  end if;
  -- F2  the UNEARNED milestone on the same overdue card was not withdrawn: nothing was earned,
  --     so there is nothing to lose.
  if exists (select 1 from public.stamp_reward_expiries_v464
              where business_id = v_biz and reward_id = v_reward_big) then
    raise exception 'D FAIL: the sweep withdrew a milestone the customer never reached';
  end if;
  -- F3  client 1 (no deadline) and client 3 (deadline in the future) were left alone.
  if exists (select 1 from public.stamp_reward_expiries_v464
              where business_id = v_biz and client_id in (v_client1, v_client3)) then
    raise exception 'D FAIL: the sweep withdrew a reward that was not overdue';
  end if;

  select count(*) into v_n from public.audit_log
   where business_id = v_biz and action = 'stamp_reward.expired';
  if v_n <> 1 then
    raise exception 'D FAIL: % owner-visible audit rows for the withdrawal (expected 1)', v_n;
  end if;

  -- F4  idempotent: running it again writes nothing.
  select app.run_stamp_reward_expiry_for_business(v_biz) into v_n;
  if v_n <> 0 then
    raise exception 'D FAIL: a second sweep withdrew % more rewards', v_n;
  end if;

  -- The customer's History carries the entry, next to what they redeemed.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust_b, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_json := public.customer_get_reward_history_v422('v464-scratch-kopi', 50);
  execute 'reset role';
  if not exists (select 1 from jsonb_array_elements(v_json -> 'items') as t(value)
                  where value ->> 'source' = 'expired'
                    and value ->> 'reward_name' = 'Free Kopi'
                    and value ->> 'expired_at' is not null) then
    raise exception 'D FAIL: the customer''s History does not show the withdrawal: %', v_json -> 'items';
  end if;
  raise notice 'D ok: the sweep withdrew exactly the one overdue reward, once, with a customer History entry and an owner audit row';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE E — CARD EXPIRY x REWARD EXPIRY (the protected v435 survival rule, still intact)
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_client2 uuid := (select v from _ctx where k='client2')::uuid;
  v_client3 uuid := (select v from _ctx where k='client3')::uuid;
  v_client4 uuid := (select v from _ctx where k='client4')::uuid;
  v_spine uuid := (select v from _ctx where k='spine_stamps')::uuid;
  v_branch uuid := (select v from _ctx where k='branch')::uuid;
  v_reward_free uuid := (select v from _ctx where k='reward_free')::uuid;
  v_cfg3 uuid; v_cfg4 uuid; v_n integer; v_txt text; v_row record; v_json jsonb; v_at timestamptz;
begin
  if not v464 then raise notice 'E skipped (baseline)'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- E1  A CARD VALIDITY of 15 days is added (version 3 — reward expiry 30 is inherited), and
  --     backdated to 80 days ago so the two backdated cards fall under it. Both cards are now
  --     past their CARD deadline; only client 2's REWARD is past its own.
  perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, 15, null);
  select active_config_version_id into v_cfg3 from public.businesses where id = v_biz;
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg3 and business_id = v_biz;
  if v_n is distinct from 30 then
    raise exception 'E1 FAIL: the card-validity edit lost the reward expiry (got %)', v_n;
  end if;
  update public.firm_config_versions set published_at = now() - interval '80 days'
   where id = v_cfg3 and business_id = v_biz;   -- TIME MACHINE (2)

  select app.run_stamp_expiry_for_business(v_biz) into v_n;
  if v_n <> 2 then
    raise exception 'E1 FAIL: the v435 card sweep closed % cards (expected 2)', v_n;
  end if;

  -- E2  CLIENT 3: card lapsed, reward deadline still in the future → the reward SURVIVES, keeps
  --     its own date, and the counter honours it. This is v435 rule 4/5, unweakened.
  select core.availability, core.reward_expires_at into v_txt, v_at
    from app.reward_availability_v432(v_biz, v_client3, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'available_at_counter' or v_at is null then
    raise exception 'E2 FAIL: a reward earned on a lapsed card, still inside its own deadline, reads % / %', v_txt, v_at;
  end if;
  v_json := app.redeem_reward_core(v_biz, v_client3, v_reward_free, 'v464-survivor-claim-01', v_branch, null, null)::jsonb;
  if not coalesce((v_json ->> 'from_expired_card')::boolean, false) then
    raise exception 'E2 FAIL: the survivor claim did not run as a survival claim: %', v_json;
  end if;

  -- E3  CLIENT 2: the card lapsed AFTER the reward's own deadline had already passed. This is the
  --     exact case where v435's survival arm would otherwise hand the reward over — the lapsed
  --     cycle holds 4 stamps and the milestone was never claimed — so it is the sharpest test that
  --     the two clocks are independent and the recorded withdrawal is the authority. The card
  --     itself is now a fresh empty one, so what the wallet PROMISES is honestly "3 stamps to go"
  --     on the new card; what it must never say again is "ready".
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client2, now()) core
   where core.reward_id = v_reward_free;
  if v_txt = 'available_at_counter' then
    raise exception 'E3 FAIL: a withdrawn reward came back as claimable when its card lapsed';
  end if;
  if v_txt is distinct from 'insufficient_balance' then
    raise exception 'E3 FAIL: after the card lapsed the reward reads % (expected insufficient_balance on the fresh card)', v_txt;
  end if;
  begin
    perform app.redeem_reward_core(v_biz, v_client2, v_reward_free, 'v464-expired-claim-02', v_branch, null, null);
    raise exception 'E3 FAIL: the counter honoured an expired reward from a lapsed card';
  exception when check_violation then
    get stacked diagnostics v_txt = message_text;
    if position('expired' in lower(v_txt)) = 0 then
      raise exception 'E3 FAIL: the lapsed-card refusal is "%" — not the expiry refusal, so survival handed it over', v_txt;
    end if;
  end;

  -- E4  A REWARD WITH NO DEADLINE STILL SURVIVES ITS CARD LAPSING. Version 4 keeps the 15-day
  --     card validity and CLEARS the reward expiry (0 = never), backdated to 40 days ago; client
  --     4's card starts 30 days ago, so it pins to version 4.
  perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 0);
  select active_config_version_id into v_cfg4 from public.businesses where id = v_biz;
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg4 and business_id = v_biz;
  if v_n is not null then
    raise exception 'E4 FAIL: 0 did not clear the reward expiry (got %)', v_n;
  end if;
  update public.firm_config_versions set published_at = now() - interval '40 days'
   where id = v_cfg4 and business_id = v_biz;   -- TIME MACHINE (2)

  declare v_s4 uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    perform set_config('app.points_ledger_insert_id', v_s4::text, true);
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id, created_at)
    values (v_s4, v_biz, v_client4, 'adjust', 4, 'v464 backdated card (30d)', v_owner, v_spine, now() - interval '30 days');
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining, earned_at)
  values (v_biz, v_client4, v_spine, 4, 4, now() - interval '30 days');
  if app.stamp_cycle_version_v416(v_biz, v_client4, v_spine) <> v_cfg4 then
    raise exception 'E4 FAIL (fixture): client 4''s card did not pin to version 4';
  end if;

  select app.run_stamp_expiry_for_business(v_biz) into v_n;
  if v_n < 1 then
    raise exception 'E4 FAIL: client 4''s 30-day-old card did not lapse under a 15-day validity';
  end if;
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client4, v_spine, 0, 3);
  if v_row.expires_at is not null then
    raise exception 'E4 FAIL: a reward under a version with NO expiry acquired one (%)', v_row.expires_at;
  end if;
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client4, now()) core
   where core.reward_id = v_reward_free;
  if v_txt is distinct from 'available_at_counter' then
    raise exception 'E4 FAIL: a reward with NO deadline did not survive its card lapsing (reads %)', v_txt;
  end if;
  v_json := app.redeem_reward_core(v_biz, v_client4, v_reward_free, 'v464-nodeadline-claim-01', v_branch, null, null)::jsonb;
  if not coalesce((v_json ->> 'from_expired_card')::boolean, false) then
    raise exception 'E4 FAIL: the no-deadline survivor claim did not run as a survival claim: %', v_json;
  end if;

  -- F5  and the sweep still never touches a reward with no deadline.
  select app.run_stamp_reward_expiry_for_business(v_biz) into v_n;
  if v_n <> 0 then
    raise exception 'F5 FAIL: the sweep withdrew % rewards that have no deadline', v_n;
  end if;
  raise notice 'E ok: card expiry and reward expiry are independent — no deadline survives the card, a deadline is honoured whatever the card is doing';
end $$;
commit;

select pg_sleep(0.05);

-- ============================================================================================
-- PHASE F — THE APPEND-ONLY GUARD KNOWS THE NEW COLUMN
--
-- business_set_earning_rule_v359 takes the v433 SPLIT path only while the stamps spine is
-- running. With stamps switched off it writes straight to the PUBLISHED version, behind
-- app.loyalty_version_immutable_guard's allowlist of owner-editable columns. v464 adds the new
-- column to that list; without it this save is refused with 'published configuration rows are
-- immutable' — the same trap nestly_v433 pre-empted for stamp_validity_days.
-- ============================================================================================
begin;
do $$
declare
  v464 boolean := to_regprocedure('app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)') is not null;
  v_biz uuid := (select v from _ctx where k='biz')::uuid;
  v_owner uuid := (select v from _ctx where k='owner')::uuid;
  v_spine uuid := (select v from _ctx where k='spine_stamps')::uuid;
  v_active uuid; v_n integer;
begin
  if not v464 then raise notice 'F skipped (baseline)'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  update public.business_programmes set active = false where id = v_spine;
  select active_config_version_id into v_active from public.businesses where id = v_biz;
  perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 60);
  if (select active_config_version_id from public.businesses where id = v_biz) <> v_active then
    raise exception 'F FAIL (fixture): the save split a version — this phase must exercise the in-place branch';
  end if;
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_active and business_id = v_biz;
  if v_n is distinct from 60 then
    raise exception 'F FAIL: the in-place save did not store the reward expiry (got %)', v_n;
  end if;
  update public.business_programmes set active = true where id = v_spine;
  raise notice 'F ok: a stamps-off firm can still set the reward expiry — the append-only guard lists the new column';
end $$;
commit;
