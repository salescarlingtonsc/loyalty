-- Rollback-only acceptance for nestly_v496 — the full card rolls when its owner looks, and
-- earned gifts stack. Run: supabase db query --linked -f db/tests/v496_full_card_rolls_and_gifts_stack.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Synthetic fixture (the v464 recipe, compact): a 5-slot stamp card, spend S$5/stamp, a gift
-- "ABC" at slot 2 and a "Final Gift" at slot 5. Customer X holds 7 stamps — a full card plus 2
-- excess, exactly the owner's photo-1 state scaled down. Customer Y holds 3 — the negative
-- control the rollover must not touch.
--
--   01  the fixture is the photo: filled 7 of 5, cycle 0, nothing closed
--   02  the CUSTOMER's own look rolls it: rolled=1, the card now reads 2/5 on cycle 1, and the
--       closed cycle is origin='completed' with slots=5 (the excess carried, nothing forfeited)
--   03  STACKING IS VISIBLE: ABC was earned on the closed card (survivor) AND is earned again on
--       the open one (2 filled >= slot 2) — one row, quantity 2, available_at_counter.
--       The Final Gift survives the closed card alone — quantity 1.
--   04  the pill agrees: customer_ready_reward_count_v465 counts INSTANCES (2 + 1 = 3)
--   05  REDEEM TWICE: the first claim lands on the OPEN card (from_expired_card=false); the
--       second falls through to the closed card's survivor (from_expired_card=true) — the exact
--       path the unpatched core refused with "already been claimed on this card"; a third is
--       refused. Availability tracks 2 -> 1 -> 0 the whole way.
--   06  idempotent and bounded: a second look rolls nothing, and customer Y's 3/5 card is
--       untouched by their own look
begin;

create temp table _r(k text, v text) on commit drop;

-- Identity only, no SET ROLE: the functions under test are all SECURITY DEFINER, so what they
-- enforce is auth.uid() — and the fixture's direct table writes (a suite device, not a product
-- path) still need the session's own privileges. v464 sets its owner identity the same way.
create or replace function pg_temp.as_v496_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v496_user(uuid) to public;

-- The guarded door onto points_ledger, same as v464's fixture writer.
create or replace function pg_temp.v496_ledger(
  p_biz uuid, p_client uuid, p_programme uuid, p_points integer, p_actor uuid)
returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_biz);
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger(id, business_id, client_id, programme_id,
                                   entry_type, points, reference, actor)
  values (v_id, p_biz, p_client, p_programme, 'adjust', p_points,
          'v496 acceptance fixture', p_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
end
$$;
grant execute on function pg_temp.v496_ledger(uuid, uuid, uuid, integer, uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_spine uuid;
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v496-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_cfg uuid;
  v_client_x uuid := gen_random_uuid();
  v_client_y uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_link_y uuid := gen_random_uuid();
  v_abc uuid := gen_random_uuid();
  v_final uuid := gen_random_uuid();
  v_json jsonb; v_row record; v_n integer; v_qty integer; v_txt text;
begin
  -- ==========================================================================================
  -- FIXTURE
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V496 Acceptance', v_slug, array['loyalty'], 'redeem');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true;
  select id into v_spine from public.business_programmes
   where business_id = v_biz and kind = 'stamps';
  update public.business_programmes set active = false
   where business_id = v_biz and kind = 'points';

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v496-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_cust, 'authenticated', 'authenticated',
          'zz-v496-cust-' || substr(v_cust::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V496 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v496 acceptance',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;

  perform pg_temp.as_v496_user(v_owner);

  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, stamp_target, stamp_per_cents)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500)
  on conflict (business_id) do update
    set active = true, loyalty_model = 'stamps', kind = 'stamps',
        configuration_status = 'published', stamp_target = 5, stamp_per_cents = 500;
  select id into v_cfg from public.firm_config_versions
   where business_id = v_biz and status = 'published' order by version_no desc limit 1;


  insert into public.clients(id, business_id, full_name, phone) values
    (v_client_x, v_biz, 'V496 X', '+65 9496 1001'),
    (v_client_y, v_biz, 'V496 Y', '+65 9496 1002');
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_biz, v_identity, v_cust, v_client_x, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values (v_abc,   v_biz, 'ABC',        'ABC',        'ABC',        'manual_item', 2, 0, 0, true, false, 1, v_spine),
         (v_final, v_biz, 'Final Gift', 'Final Gift', 'Final Gift', 'manual_item', 5, 0, 0, true, false, 2, v_spine);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, sort, programme_id)
  select r.id, v_biz, v_cfg, r.name, r.name, 'manual_item', r.cost, 0, 0, r.sort, v_spine
    from (values (v_abc, 'ABC', 2, 1), (v_final, 'Final Gift', 5, 2)) as r(id, name, cost, sort);

  perform pg_temp.v496_ledger(v_biz, v_client_x, v_spine, 7, v_owner);
  perform pg_temp.v496_ledger(v_biz, v_client_y, v_spine, 3, v_owner);

  -- ==========================================================================================
  -- 01  THE PHOTO: a full card that has not rolled
  -- ==========================================================================================
  select sp.slots, sp.filled, sp.cycle_index into v_row
    from app.stamp_progress_v323(v_biz, v_client_x) sp limit 1;
  insert into _r values('01_full_card_unrolled',
    case when v_row.slots = 5 and v_row.filled = 7 and v_row.cycle_index = 0
      then 'PASS 7 of 5 on cycle 0 — the owner''s photo-1 state'
      else 'FAIL slots=' || v_row.slots || ' filled=' || v_row.filled || ' cycle=' || v_row.cycle_index end);

  -- ==========================================================================================
  -- 02  THE CUSTOMER'S OWN LOOK ROLLS IT
  -- ==========================================================================================
  perform pg_temp.as_v496_user(v_cust);
  v_json := public.customer_rollover_full_stamp_card_v496(v_slug);

  insert into _r values('02_look_rolls',
    case when (v_json ->> 'rolled')::integer = 1
      then 'PASS the wallet''s look closed one cycle'
      else 'FAIL rolled=' || coalesce(v_json ->> 'rolled', 'null') end);
  select sp.slots, sp.filled, sp.cycle_index into v_row
    from app.stamp_progress_v323(v_biz, v_client_x) sp limit 1;
  insert into _r values('02_fresh_card_carries_excess',
    case when v_row.filled = 2 and v_row.cycle_index = 1
      then 'PASS the customer now sees 2/5 on a fresh card'
      else 'FAIL filled=' || v_row.filled || ' cycle=' || v_row.cycle_index end);
  select count(*) into v_n from public.stamp_cycles
   where business_id = v_biz and client_id = v_client_x
     and cycle_index = 0 and origin = 'completed' and slots = 5;
  insert into _r values('02_completed_close_shape',
    case when v_n = 1 then 'PASS closed with slots=5, origin completed — nothing forfeited'
         else 'FAIL ' || v_n || ' matching cycle rows' end);

  -- ==========================================================================================
  -- 03  STACKING IS VISIBLE: one row, quantity 2
  -- ==========================================================================================
  select r.quantity, r.availability into v_qty, v_txt
    from app.reward_availability_v432(v_biz, v_client_x, now()) r where r.reward_id = v_abc;
  insert into _r values('03_abc_stacks_to_two',
    case when v_qty = 2 and v_txt = 'available_at_counter'
      then 'PASS ABC: survivor + fresh-card earn = quantity 2, claimable'
      else 'FAIL quantity=' || coalesce(v_qty::text, 'null') || ' availability=' || coalesce(v_txt, 'null') end);
  select r.quantity, r.availability into v_qty, v_txt
    from app.reward_availability_v432(v_biz, v_client_x, now()) r where r.reward_id = v_final;
  insert into _r values('03_final_survives_once',
    case when v_qty = 1 and v_txt = 'available_at_counter'
      then 'PASS the unclaimed 5-slot gift outlives its card, quantity 1'
      else 'FAIL quantity=' || coalesce(v_qty::text, 'null') || ' availability=' || coalesce(v_txt, 'null') end);

  -- ==========================================================================================
  -- 04  THE PILL COUNTS INSTANCES
  -- ==========================================================================================
  select (app.customer_ready_reward_count_v465(v_biz, v_client_x, now()) ->> 'count')::integer into v_n;
  insert into _r values('04_ready_count_is_instances',
    case when v_n = 3 then 'PASS 2 x ABC + 1 x Final Gift = 3 rewards ready'
         else 'FAIL count=' || coalesce(v_n::text, 'null') end);

  -- ==========================================================================================
  -- 05  REDEEM TWICE — open card first, then the survivor
  -- ==========================================================================================
  perform pg_temp.as_v496_user(v_owner);
  v_json := app.redeem_reward_core(v_biz, v_client_x, v_abc, 'v496-acc-abc-1', v_branch, null, null)::jsonb;
  insert into _r values('05_first_claim_open_card',
    case when coalesce((v_json ->> 'from_expired_card')::boolean, true) = false
          and (v_json ->> 'stamp_cycle_index')::integer = 1
      then 'PASS first instance settled on the OPEN card (cycle 1)'
      else 'FAIL ' || v_json::text end);

  select r.quantity into v_qty
    from app.reward_availability_v432(v_biz, v_client_x, now()) r where r.reward_id = v_abc;
  insert into _r values('05_quantity_tracks_down',
    case when v_qty = 1 then 'PASS quantity 2 -> 1 after the first claim'
         else 'FAIL quantity=' || coalesce(v_qty::text, 'null') end);
  perform pg_temp.as_v496_user(v_owner);
  v_json := app.redeem_reward_core(v_biz, v_client_x, v_abc, 'v496-acc-abc-2', v_branch, null, null)::jsonb;
  insert into _r values('05_second_claim_survivor',
    case when coalesce((v_json ->> 'from_expired_card')::boolean, false)
          and (v_json ->> 'stamp_cycle_index')::integer = 0
      then 'PASS second instance fell through to the closed card''s survivor (cycle 0)'
      else 'FAIL ' || v_json::text end);
  begin
    perform app.redeem_reward_core(v_biz, v_client_x, v_abc, 'v496-acc-abc-3', v_branch, null, null);
    insert into _r values('05_third_claim_refused', 'FAIL a third instance was honoured where only two exist');
  exception when others then
    insert into _r values('05_third_claim_refused', 'PASS the counter refuses a third: ' || sqlerrm);
  end;

  select r.quantity into v_qty
    from app.reward_availability_v432(v_biz, v_client_x, now()) r where r.reward_id = v_abc;
  insert into _r values('05_quantity_reaches_zero',
    case when coalesce(v_qty, 0) = 0 then 'PASS nothing claimable is left to promise'
         else 'FAIL quantity=' || coalesce(v_qty::text, 'null') end);

  -- ==========================================================================================
  -- 06  IDEMPOTENT, AND BOUNDED TO FULL CARDS
  -- ==========================================================================================
  perform pg_temp.as_v496_user(v_cust);
  v_json := public.customer_rollover_full_stamp_card_v496(v_slug);

  insert into _r values('06_second_look_rolls_nothing',
    case when (v_json ->> 'rolled')::integer = 0
      then 'PASS a replayed look closes nothing twice'
      else 'FAIL rolled=' || coalesce(v_json ->> 'rolled', 'null') end);
  -- Y's 3/5 card via a direct engine call (Y holds no login; the engine is what the RPC wraps).
  v_n := app.stamp_complete_full_cycle_v489(v_biz, v_client_y, v_spine);
  select sp.filled, sp.cycle_index into v_row
    from app.stamp_progress_v323(v_biz, v_client_y) sp limit 1;
  insert into _r values('06_partial_card_untouched',
    case when v_n = 0 and v_row.filled = 3 and v_row.cycle_index = 0
      then 'PASS a 3/5 card does not roll'
      else 'FAIL rolled=' || v_n || ' filled=' || v_row.filled || ' cycle=' || v_row.cycle_index end);
end $$;

select * from _r order by k;
rollback;
