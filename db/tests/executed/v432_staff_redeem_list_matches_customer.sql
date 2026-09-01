-- EXECUTED acceptance for nestly_v432 — the staff redeem-now list offers exactly what the
-- customer can redeem, from the same canonical availability core.
--
--   psql -v ON_ERROR_STOP=1 -f db/tests/executed/v432_staff_redeem_list_matches_customer.sql
--
-- Dual-mode: BASELINE (pre-v432) pins the DEFECT — the staff projection offers a points-programme
-- gift whose points spine is switched off, and a stamp gift priced past the card's end, judged
-- "affordable" against a STAMP balance — while the customer's own catalogue excludes the first.
-- MIGRATED pins the fix: staff and Customer View list the same two claimable stamp gifts, the
-- unrelated catalogue gifts never appear as redeemable, and a mid-card claim drops that gift from
-- the redeem-now list without touching the stamp balance (redemption semantics unchanged).
--
-- Self-contained: builds its own scratch tenant, drives the real RPCs under
-- set_config('request.jwt.claims', ...) + `set local role authenticated`, and ROLLS BACK.
-- Every check RAISEs on failure.

begin;

do $$
declare
  v_has_v432 boolean := position('nestly_v432' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = 'staff_get_customer_actionable_loyalty_v145'), '')) > 0;
  v_biz uuid := gen_random_uuid();
  v_cfg uuid;
  v_spine_stamps uuid := gen_random_uuid();
  v_spine_points uuid;
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_reward_a uuid := gen_random_uuid();  -- 'Card Gift A', 5 stamps  (final slot)
  v_reward_b uuid := gen_random_uuid();  -- 'Card Gift B', 3 stamps  (mid-card)
  v_reward_c uuid := gen_random_uuid();  -- 'Off Points Gift', 10 points — points spine OFF
  v_reward_d uuid := gen_random_uuid();  -- 'Past End Gift', 8 stamps — past the 5-slot card
  v_branch uuid := gen_random_uuid();
  v_staff jsonb; v_cat jsonb; v_actions jsonb; v_row jsonb;
  v_staff_avail text; v_cat_avail text; v_actions_avail text;
  v_n integer; v_pot integer;
begin
  -- ==========================================================================================
  -- SCRATCH TENANT — a stamps-engine firm shaped like the live defect (points spine off)
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V432 Scratch Cafe', 'v432-scratch-cafe', array['loyalty'], 'redeem');

  -- The harness runs the real seed triggers: claim the seeded spine rows.
  -- sort must match kind (business_programmes_sort_matches_kind): stamps = 3.
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
    'zz-v432-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cust,'authenticated','authenticated',
    'zz-v432-cust-'||substr(v_cust::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, active)
  values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V432 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v432 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused=false;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved+unpaused workspace above.
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true)
  on conflict (business_id) do update set redemption_enabled = true;

  -- The c45 write guards fire on the FIXTURE's own inserts, so the owner identity is assumed
  -- before any guarded loyalty write (v431 lesson).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.loyalty_programs(business_id, active, loyalty_model, kind, configuration_status,
                                      stamp_target, stamp_per_cents)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500)
  on conflict (business_id) do update
    set active=true, loyalty_model='stamps', kind='stamps',
        configuration_status='published', stamp_target=5, stamp_per_cents=500;

  -- Adopt the version the seed trigger published (firm_config_one_published_per_business).
  select id into v_cfg from public.firm_config_versions
   where business_id = v_biz and status = 'published'
   order by version_no desc limit 1;
  if v_cfg is null then
    v_cfg := gen_random_uuid();
    insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash, published_at)
    select v_cfg, v_biz, coalesce(max(version_no), 0) + 1, 'published', md5('v432-published'), now()
      from public.firm_config_versions where business_id = v_biz;
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;

  -- Customer + verified link (route-token recipe).
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V432 Scratch Customer', '+65 9432 0001');
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  declare v_link uuid := gen_random_uuid(); begin
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link, v_biz, v_identity, v_cust, v_client, 'verified', 'phone_claim', now());
    perform set_config('app.customer_link_insert_id', '', true);
  end;

  -- 12 stamps in the stamps pot: the card (5 slots) is complete with carry-over, both on-card
  -- gifts claimable — and 12 also exceeds every "cost" below, which is exactly what let the
  -- baseline projection cross-price points gifts against a stamp balance.
  perform app.acquire_loyalty_shared_v480(v_biz);
  declare v_seed uuid := gen_random_uuid(); begin
    perform set_config('app.points_ledger_insert_id', v_seed::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    -- adjust_points requires actor = auth.uid(); the owner claims are already assumed above.
    insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference, actor, programme_id)
    values (v_seed, v_biz, v_client, 'adjust', 12, 'v432 executed-test seed stamps', v_owner, v_spine_stamps);
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);
  end;
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining)
  values (v_biz, v_client, v_spine_stamps, 12, 12);

  -- The four catalogue gifts.
  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values
    (v_reward_a, v_biz, 'Card Gift A', 'Card Gift A', 'Card Gift A', 'manual_item', 5, 0, 0, true, false, 1, v_spine_stamps),
    (v_reward_b, v_biz, 'Card Gift B', 'Card Gift B', 'Card Gift B', 'manual_item', 3, 0, 0, true, false, 2, v_spine_stamps),
    (v_reward_c, v_biz, 'Off Points Gift', 'Off Points Gift', 'Off Points Gift', 'manual_item', 10, 0, 0, true, false, 3, v_spine_points),
    (v_reward_d, v_biz, 'Past End Gift', 'Past End Gift', 'Past End Gift', 'manual_item', 8, 0, 0, true, false, 4, v_spine_stamps);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, description, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, image_ref, sort, programme_id)
  values
    (v_reward_a, v_biz, v_cfg, 'Card Gift A', 'Card Gift A', 'On the card', 'manual_item', 5, 0, 0, null, 1, v_spine_stamps),
    (v_reward_b, v_biz, v_cfg, 'Card Gift B', 'Card Gift B', 'On the card', 'manual_item', 3, 0, 0, null, 2, v_spine_stamps),
    (v_reward_c, v_biz, v_cfg, 'Off Points Gift', 'Off Points Gift', 'Wrong engine', 'manual_item', 10, 0, 0, null, 3, v_spine_points),
    (v_reward_d, v_biz, v_cfg, 'Past End Gift', 'Past End Gift', 'Past the card', 'manual_item', 8, 0, 0, null, 4, v_spine_stamps);

  -- ==========================================================================================
  -- 01  STAFF REDEEM-NOW LIST (as the owner, role authenticated)
  -- ==========================================================================================
  execute 'set local role authenticated';
  v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client, null);
  execute 'reset role';

  select string_agg(value ->> 'name', ',' order by value ->> 'name')
    into v_staff_avail
    from jsonb_array_elements(v_staff -> 'rewards')
   where (value ->> 'available_now')::boolean;

  if v_has_v432 then
    if coalesce(v_staff_avail, '') <> 'Card Gift A,Card Gift B' then
      raise exception '01 FAIL (migrated): staff redeem-now offers [%], expected exactly the two on-card gifts', v_staff_avail;
    end if;
    select count(*) into v_n from jsonb_array_elements(v_staff -> 'rewards');
    if v_n <> 2 then
      raise exception '01 FAIL (migrated): staff list carries % rows — the off-programme and past-end gifts must not be listed at all: %',
        v_n, v_staff -> 'rewards';
    end if;
    for v_row in select value from jsonb_array_elements(v_staff -> 'rewards') loop
      if v_row ->> 'source' <> 'stamp_card' or v_row ->> 'unit' <> 'stamps' then
        raise exception '01 FAIL (migrated): reward % is not labelled from the stamp card: %',
          v_row ->> 'name', v_row;
      end if;
    end loop;
    raise notice '01 ok (migrated): staff redeem-now = exactly the customer''s two on-card gifts, labelled Stamp card';
  else
    if v_staff_avail is null
       or position('Off Points Gift' in v_staff_avail) = 0
       or position('Past End Gift' in v_staff_avail) = 0 then
      raise exception '01 FAIL (baseline): expected the DEFECT (off-programme and past-end gifts offered as redeemable), got [%] — the environment does not match production', v_staff_avail;
    end if;
    raise notice '01 ok (baseline): DEFECT REPRODUCED — staff redeem-now offered [%]', v_staff_avail;
  end if;

  -- ==========================================================================================
  -- 02  CUSTOMER CATALOGUE (as the customer) — the canonical view staff must match
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_cat := public.customer_get_reward_catalog('v432-scratch-cafe');
  v_actions := public.customer_get_business_actions_v89(v_biz);
  execute 'reset role';

  select string_agg(value ->> 'customer_name', ',' order by value ->> 'customer_name')
    into v_cat_avail
    from jsonb_array_elements(v_cat -> 'rewards')
   where value ->> 'availability' = 'available_at_counter';
  select string_agg(value ->> 'name', ',' order by value ->> 'name')
    into v_actions_avail
    from jsonb_array_elements(v_actions -> 'rewards')
   where value ->> 'availability' = 'available_at_counter';

  if coalesce(v_cat_avail, '') <> 'Card Gift A,Card Gift B' then
    raise exception '02 FAIL: customer catalogue offers [%], expected the two on-card gifts', v_cat_avail;
  end if;
  if exists (select 1 from jsonb_array_elements(v_cat -> 'rewards')
              where value ->> 'customer_name' = 'Off Points Gift') then
    raise exception '02 FAIL: a points gift on a switched-off spine is in the customer catalogue';
  end if;
  if v_has_v432 then
    select value ->> 'availability' into v_cat_avail
      from jsonb_array_elements(v_cat -> 'rewards')
     where value ->> 'customer_name' = 'Past End Gift';
    if v_cat_avail is distinct from 'not_on_card' then
      raise exception '02 FAIL (migrated): the past-end gift reads %, expected not_on_card', v_cat_avail;
    end if;
    if coalesce(v_actions_avail, '') <> 'Card Gift A,Card Gift B' then
      raise exception '02 FAIL (migrated): customer home actions offer [%], expected the two on-card gifts', v_actions_avail;
    end if;
    raise notice '02 ok (migrated): Customer View and staff redeem-now agree — same two gifts, past-end gift truthfully not_on_card';
  else
    raise notice '02 ok (baseline): the customer catalogue already excluded the off-programme gift — the staff list above is the divergence';
  end if;

  -- ==========================================================================================
  -- 03  A MID-CARD CLAIM drops that gift from redeem-now and touches no balance
  --     (redemption semantics unchanged — nestly_v432 is read-side only)
  -- ==========================================================================================
  if v_has_v432 then
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    -- the redemption branch rule (enforce_loyalty_redemption_branch_v94) wants a real, active
    -- branch on the claim — the same thing the till passes.
    perform app.redeem_reward_core(v_biz, v_client, v_reward_b, 'v432-claim-gift-b-0001', v_branch, null, null);

    select coalesce(sum(points), 0)::integer into v_pot
      from public.points_ledger
     where business_id = v_biz and client_id = v_client and programme_id = v_spine_stamps;
    if v_pot <> 12 then
      raise exception '03 FAIL: a mid-card stamp claim moved the pot (% <> 12) — stamps must not be deducted', v_pot;
    end if;

    execute 'set local role authenticated';
    v_staff := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client, null);
    execute 'reset role';
    select string_agg(value ->> 'name', ',' order by value ->> 'name')
      into v_staff_avail
      from jsonb_array_elements(v_staff -> 'rewards')
     where (value ->> 'available_now')::boolean;
    if coalesce(v_staff_avail, '') <> 'Card Gift A' then
      raise exception '03 FAIL: after claiming Card Gift B this cycle, staff redeem-now offers [%], expected only Card Gift A', v_staff_avail;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_cat := public.customer_get_reward_catalog('v432-scratch-cafe');
    execute 'reset role';
    select value ->> 'availability' into v_cat_avail
      from jsonb_array_elements(v_cat -> 'rewards')
     where value ->> 'customer_name' = 'Card Gift B';
    if v_cat_avail is distinct from 'claimed_this_cycle' then
      raise exception '03 FAIL: the claimed gift reads % in the customer catalogue, expected claimed_this_cycle', v_cat_avail;
    end if;
    raise notice '03 ok (migrated): the claim moved the gift out of redeem-now on BOTH sides and left the stamp balance alone';
  else
    raise notice '03 skipped (baseline): claim behaviour is asserted in migrated mode';
  end if;

  perform set_config('request.jwt.claims', '{}', true);
end $$;

rollback;
select 'v432 executed acceptance finished (see notices)' as result;
