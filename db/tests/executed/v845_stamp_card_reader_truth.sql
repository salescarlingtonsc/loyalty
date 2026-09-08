-- EXECUTED acceptance fixture for nestly_v845
-- (db/migrations/20261008_nestly_v845_stamp_card_reader_truth.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v845
--
-- WHY THIS EXISTS. public.customer_get_stamp_card_v323(text) is the only reader behind the
-- customer's Stamp Card screen, and it disagreed with every sibling reward reader in three ways.
-- All three were reproduced against production on 2026-09-09 inside rolled-back probes:
--
--   (A) kopi-tiam-tyeh (business 8492e8d6-…, stamps spine 708d5047-… INACTIVE), client
--       268cb96d-… with 791 stamps on a 15-slot card: the card returned running=false and yet
--       milestones [Free Lotion=available_at_counter, Free Massage Oil=available_at_counter]
--       (reward ids 0558d355-…, 430e4bad-…), while app.reward_availability_v432 for the same
--       customer listed four rows and none of them were those two. The milestone CASE asked
--       `filled >= cost_points` before `not programme_active`, so a COMPLETED card on a stopped
--       programme read READY. A partly filled one (kopi-tiam-tyeh's 3-of-5 client, kky-demo's
--       4-of-5 client) already read 'paused' correctly — only the full card fell through.
--   (B) qa-kaya-toast (business 38b30e6d-…), client 49b43e01-… with 12 closed cycles:
--       app.reward_availability_v432 offered ABC / Jffjj / Free Facial Cream at quantity 12 each
--       — 36 ready, the number on the home tile — while the card returned filled 0, carried 0 and
--       three milestones all 'insufficient_stamps' with "5 stamps to go". This reader had no
--       survivor arm; v432 (arm 1), app.customer_ready_reward_count_v465 and
--       public.customer_get_reward_catalog have had one since nestly_v489/v496.
--   (C) qa-kopi-lab (business 8ad4a375-…), client 07fd0757-…: next_milestone was "Hava a cup of
--       Milk Tea!" at slot 4 with availability 'ended' — window closed 2026-08-24 — because the
--       subquery filtered on claimed_this_cycle alone and ignored the availability it had just
--       computed.
--
-- ASSERTIONS (rows, with a fatal gate at the end). Everything is built on a tenant this file
-- creates and is rolled back:
--   T1   CONTROL — running card, 3 of 5 stamps: the slot-3 gift reads available_at_counter.
--        Without this every later assertion is vacuous.
--   T2   (A) THE BUG — with the stamps programme switched OFF, that same already-collected gift
--        reads 'paused', not 'available_at_counter'.
--   T3   (A) …and the two readers agree: app.reward_availability_v432 offers none of the card's
--        gifts while the programme is stopped.
--   T4   (A) the reorder did not swallow the branches above it — the gift whose claim window has
--        closed still reads 'ended' while the programme is stopped, not 'paused'.
--   T5   (A) switching the programme back ON restores available_at_counter. The fix is a reorder,
--        not a permanent kill.
--   T6   (C) next_milestone names the open slot-3 gift, NOT the slot-2 gift whose window closed.
--   T7   (C) …and the ended gift is still LISTED on the card, marked 'ended'. Skipping it in
--        next_milestone must not delete it from the grid.
--   T8   (C) the same holds in the post-rollover shape production showed at qa-kopi-lab
--        (filled 0 on a fresh cycle): next_milestone is still the open gift.
--   T9   (B) after the full card rolls over, carried_rewards lists the three gifts of the closed
--        cycle and carried_rewards_ready is 2 (the slot-3 and slot-5 gifts).
--   T10  (B) that count is app.reward_availability_v432's count, not a second opinion.
--   T11  (B) the dead gift survives as 'ended' and is never counted ready.
--   T12  (B) survivors do NOT leak into `milestones`: the current card's grid still has exactly
--        the three rungs, at their own slots.
--   T13  (B) claiming a survivor removes it — carried_rewards_ready drops to 1 and the claimed
--        gift is gone from carried_rewards (the not-exists against stamp_milestone_claims is
--        real, not decoration).
--   T14  (B) on a STOPPED programme the survivors read 'paused' and carried_rewards_ready is 0,
--        which is the number app.reward_availability_v432 offers. This is the one documented
--        divergence: v432 drops the rows, this reader keeps them and says why.
--
-- WHAT THIS FILE DOES NOT DO. It never touches app.redeem_reward_core beyond CALLING it (T13, on
-- a running programme), and it asserts nothing about that function's own behaviour — the counter
-- half of defect (A) is a separate migration by another agent.
--
-- TIME. now() is fixed for the whole transaction. app.stamp_cycle_version_v416 pins by
-- `published_at <= the customer's first stamp`, so the fixture backdates both the config version
-- and the first stamp, which is the ordering production has.

begin;

create temp table v845_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v845_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v845_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;

create or replace function pg_temp.v845_card(p_user uuid, p_owner uuid, p_slug text)
returns jsonb language plpgsql as $$
declare v_json jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    v_json := public.customer_get_stamp_card_v323(p_slug);
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);
    raise;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);
  return v_json;
end
$$;

do $v845_test$
declare
  v_biz uuid := gen_random_uuid();
  v_spine uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_owner_staff uuid;
  v_cust uuid := gen_random_uuid();
  v_ident uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_g2 uuid := gen_random_uuid();   -- slot 2, claim window CLOSED yesterday
  v_g3 uuid := gen_random_uuid();   -- slot 3, open
  v_g5 uuid := gen_random_uuid();   -- slot 5, the final gift on the card
  v_seed uuid := gen_random_uuid();
  v_seed2 uuid;
  v_cfg uuid;
  v_slug text;
  v_json jsonb;
  v_txt text;
  v_n integer;
  v_v432 integer;
begin
  -- ==========================================================================================
  -- FIXTURE — a stamps tenant with a five-slot card and three gifts (recipe from
  -- db/tests/executed/v805_stamp_gift_delete_version_forward.sql).
  -- ==========================================================================================
  v_slug := 'zz-v845-' || substr(v_biz::text, 1, 8);
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v845-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_cust, 'authenticated', 'authenticated',
          'zz-v845-cust-' || substr(v_cust::text, 1, 8) || '@example.test', '', now(), now(), now());

  perform set_config('app.v79_system_transition', 'on', true);
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V845 Stamp Kopi', v_slug, array['loyalty'], 'redeem');
  perform set_config('app.v79_system_transition', '', true);

  insert into public.business_programmes(id, business_id, kind, active, sort)
  values (v_spine, v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true
  returning id into v_spine;
  update public.business_programmes set active = true where business_id = v_biz and kind = 'points';

  insert into public.staff(business_id, user_id, role, active, access_state)
  values (v_biz, v_owner, 'owner', true, 'approved')
  returning id into v_owner_staff;
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V845 main', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_biz, v_owner_staff, v_branch);
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v845 acceptance fixture',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;
  insert into public.subscriptions(business_id) values (v_biz) on conflict do nothing;
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, stamp_target, stamp_per_cents)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500)
  on conflict (business_id) do update
    set active = true, loyalty_model = 'stamps', kind = 'stamps',
        configuration_status = 'published', stamp_target = 5, stamp_per_cents = 500;

  select id into v_cfg from public.firm_config_versions
   where business_id = v_biz and status = 'published' order by version_no desc limit 1;
  if v_cfg is null then
    raise exception 'FIXTURE BROKEN: the tenant published no configuration version';
  end if;
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;
  update public.firm_config_versions set published_at = now() - interval '2 days' where id = v_cfg;

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V845 Customer', '+65 9830 0001');
  insert into public.customer_identities(id, auth_user_id, status) values (v_ident, v_cust, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state,
                                    verification_method, verified_at)
  values (v_link, v_biz, v_ident, v_cust, v_client, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort,
    programme_id)
  values (v_g2, v_biz, 'Closed Window', 'Closed Window', 'Closed Window', 'manual_item', 2, 0, 0, true, false, 1, v_spine),
         (v_g3, v_biz, 'Free Coffee',   'Free Coffee',   'Free Coffee',   'manual_item', 3, 0, 0, true, false, 2, v_spine),
         (v_g5, v_biz, 'Big Gift',      'Big Gift',      'Big Gift',      'manual_item', 5, 0, 0, true, false, 3, v_spine);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, description, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, sort, programme_id, claim_available_until)
  values (v_g2, v_biz, v_cfg, 'Closed Window', 'Closed Window', 'Window shut', 'manual_item', 2, 0, 0, 1, v_spine, now() - interval '1 day'),
         (v_g3, v_biz, v_cfg, 'Free Coffee',   'Free Coffee',   'Mid card',    'manual_item', 3, 0, 0, 2, v_spine, null),
         (v_g5, v_biz, v_cfg, 'Big Gift',      'Big Gift',      'Final',       'manual_item', 5, 0, 0, 3, v_spine, null);

  /* The EXCLUSIVE fence, not the shared one: this file is a single transaction and later steps
     (app.stamp_complete_full_cycle_v489, app.redeem_reward_core) take it too. */
  perform app.acquire_loyalty_exclusive_v480(v_biz);
  perform set_config('app.points_ledger_insert_id', v_seed::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference,
                                   actor, programme_id, created_at)
  values (v_seed, v_biz, v_client, 'adjust', 3, 'v845 seed stamps', v_owner, v_spine,
          now() - interval '1 day');
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining)
  values (v_biz, v_client, v_spine, 3, 3);

  if app.stamp_cycle_version_v416(v_biz, v_client, v_spine) is distinct from v_cfg then
    raise exception 'FIXTURE BROKEN: the customer is not pinned to the published version';
  end if;

  -- ==========================================================================================
  -- PHASE 1 — the running card, 3 of 5
  -- ==========================================================================================
  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);

  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
   where value ->> 'reward_id' = v_g3::text;
  perform pg_temp.v845_note(1, 'T1 CONTROL a collected gift on a RUNNING card is claimable',
    coalesce(v_txt, 'ABSENT') = 'available_at_counter',
    'slot-3 gift=' || coalesce(v_txt, 'ABSENT') || ' filled=' || coalesce(v_json ->> 'filled', 'null'));

  perform pg_temp.v845_note(6, 'T6 next_milestone skips the gift whose claim window closed',
    coalesce(v_json -> 'next_milestone' ->> 'reward_id', 'NULL') = v_g3::text,
    'next=' || coalesce(v_json -> 'next_milestone' ->> 'name', 'NULL')
      || '/' || coalesce(v_json -> 'next_milestone' ->> 'availability', 'NULL'));

  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
   where value ->> 'reward_id' = v_g2::text;
  perform pg_temp.v845_note(7, 'T7 the ended gift is still listed on the card, marked ended',
    coalesce(v_txt, 'ABSENT') = 'ended', 'slot-2 gift=' || coalesce(v_txt, 'ABSENT'));

  -- ==========================================================================================
  -- PHASE 2 — the owner switches the stamps programme OFF
  -- ==========================================================================================
  update public.business_programmes set active = false, deactivated_at = now() where id = v_spine;
  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);

  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
   where value ->> 'reward_id' = v_g3::text;
  perform pg_temp.v845_note(2, 'T2 THE BUG — a collected gift on a STOPPED programme is not READY',
    coalesce(v_txt, 'ABSENT') = 'paused',
    'slot-3 gift=' || coalesce(v_txt, 'ABSENT') || ' running=' || coalesce(v_json ->> 'running', 'null'));

  select count(*) into v_n from app.reward_availability_v432(v_biz, v_client) ra
   where ra.reward_id in (v_g2, v_g3, v_g5);
  perform pg_temp.v845_note(3, 'T3 the counter offers none of them while the programme is stopped',
    v_n = 0, 'app.reward_availability_v432 rows=' || v_n);

  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
   where value ->> 'reward_id' = v_g2::text;
  perform pg_temp.v845_note(4, 'T4 paused did not swallow ended — the closed window still wins',
    coalesce(v_txt, 'ABSENT') = 'ended', 'slot-2 gift=' || coalesce(v_txt, 'ABSENT'));

  -- ==========================================================================================
  -- PHASE 3 — and back ON
  -- ==========================================================================================
  update public.business_programmes set active = true, deactivated_at = null where id = v_spine;
  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);
  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
   where value ->> 'reward_id' = v_g3::text;
  perform pg_temp.v845_note(5, 'T5 restarting the programme gives the gift back',
    coalesce(v_txt, 'ABSENT') = 'available_at_counter', 'slot-3 gift=' || coalesce(v_txt, 'ABSENT'));

  -- ==========================================================================================
  -- PHASE 4 — the card fills up and rolls over; the gifts on the finished cycle survive
  -- ==========================================================================================
  v_seed2 := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id', v_seed2::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger(id, business_id, client_id, entry_type, points, reference,
                                   actor, programme_id, created_at)
  values (v_seed2, v_biz, v_client, 'adjust', 2, 'v845 fill the card', v_owner, v_spine, now());
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  perform app.stamp_complete_full_cycle_v489(v_biz, v_client, v_spine);

  select count(*) into v_n from public.stamp_cycles
   where business_id = v_biz and client_id = v_client and origin = 'completed';
  if v_n <> 1 then
    raise exception 'FIXTURE BROKEN: the full card did not close (% completed cycles)', v_n;
  end if;

  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);
  if coalesce((v_json ->> 'filled')::integer, -1) <> 0 then
    raise exception 'FIXTURE BROKEN: the fresh card is not empty (filled=%)', v_json ->> 'filled';
  end if;

  perform pg_temp.v845_note(8, 'T8 next_milestone is still the reachable gift after the rollover',
    coalesce(v_json -> 'next_milestone' ->> 'reward_id', 'NULL') = v_g3::text,
    'next=' || coalesce(v_json -> 'next_milestone' ->> 'name', 'NULL')
      || '/' || coalesce(v_json -> 'next_milestone' ->> 'availability', 'NULL'));

  perform pg_temp.v845_note(9, 'T9 the finished cycle''s gifts survive on carried_rewards',
    jsonb_array_length(coalesce(v_json -> 'carried_rewards', '[]'::jsonb)) = 3
      and coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) = 2,
    'carried_rewards=' || jsonb_array_length(coalesce(v_json -> 'carried_rewards', '[]'::jsonb))
      || ' ready=' || coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT'));

  select coalesce(sum(ra.quantity), 0)::integer into v_v432
    from app.reward_availability_v432(v_biz, v_client) ra
   where ra.availability = 'available_at_counter' and ra.unit = 'stamps';
  perform pg_temp.v845_note(10, 'T10 that count is app.reward_availability_v432''s, not a second opinion',
    coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) = v_v432,
    'card=' || coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT') || ' v432=' || v_v432);

  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'carried_rewards')
   where value ->> 'reward_id' = v_g2::text;
  perform pg_temp.v845_note(11, 'T11 the dead gift survives as ended and is never counted ready',
    coalesce(v_txt, 'ABSENT') = 'ended', 'survivor of the closed window=' || coalesce(v_txt, 'ABSENT'));

  select string_agg(value ->> 'slot', ',' order by (value ->> 'slot')::integer) into v_txt
    from jsonb_array_elements(v_json -> 'milestones');
  perform pg_temp.v845_note(12, 'T12 survivors do not leak into the current card''s grid',
    jsonb_array_length(v_json -> 'milestones') = 3 and v_txt = '2,3,5',
    'milestones=' || jsonb_array_length(v_json -> 'milestones') || ' slots=' || coalesce(v_txt, 'null'));

  -- ==========================================================================================
  -- PHASE 5 — claiming a survivor takes it off the list
  -- ==========================================================================================
  perform app.redeem_reward_core(v_biz, v_client, v_g3, 'v845-survivor-claim-01', v_branch);
  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);
  perform pg_temp.v845_note(13, 'T13 a claimed survivor disappears from carried_rewards',
    coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) = 1
      and not exists (select 1 from jsonb_array_elements(v_json -> 'carried_rewards') c
                       where c.value ->> 'reward_id' = v_g3::text),
    'ready=' || coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT')
      || ' still listed=' || (exists (select 1 from jsonb_array_elements(v_json -> 'carried_rewards') c
                                       where c.value ->> 'reward_id' = v_g3::text))::text);

  -- ==========================================================================================
  -- PHASE 6 — the documented divergence: a stopped programme pauses the survivors
  -- ==========================================================================================
  update public.business_programmes set active = false, deactivated_at = now() where id = v_spine;
  v_json := pg_temp.v845_card(v_cust, v_owner, v_slug);
  select coalesce(sum(ra.quantity), 0)::integer into v_v432
    from app.reward_availability_v432(v_biz, v_client) ra
   where ra.availability = 'available_at_counter' and ra.unit = 'stamps';
  select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'carried_rewards')
   where value ->> 'reward_id' = v_g5::text;
  perform pg_temp.v845_note(14, 'T14 a stopped programme pauses the survivors and offers none',
    coalesce(v_txt, 'ABSENT') = 'paused'
      and coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) = 0
      and v_v432 = 0,
    'survivor=' || coalesce(v_txt, 'ABSENT')
      || ' card ready=' || coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT')
      || ' v432 ready=' || v_v432);
end
$v845_test$;

select seq, step, outcome, detail from v845_out order by seq;

do $gate$
declare v_failed integer; v_total integer;
begin
  select count(*) filter (where outcome <> 'PASS'), count(*) into v_failed, v_total from v845_out;
  if v_total <> 14 then
    raise exception 'nestly_v845 acceptance: % assertion(s) recorded, expected 14 — the suite '
                    'aborted before it finished', v_total;
  end if;
  if v_failed > 0 then
    raise exception 'nestly_v845 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
