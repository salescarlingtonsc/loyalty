-- Rollback-only acceptance for nestly_v464 — owner-set expiry on EARNED stamp rewards (R3(e)).
--   supabase db query --linked -f db/tests/v464_earned_reward_expiry.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check CALLS the real engine — app.stamp_reward_expiry_v464, app.reward_availability_v432,
-- app.redeem_reward_core, public.staff_get_customer_actionable_loyalty_v145,
-- public.customer_get_reward_history_v422, app.stamp_reward_expire_due_v464 and v435's own card
-- sweep. No check reads a function's source text.
--
--   01  fixture shape: three published versions on a timeline, four customers whose cards each
--       pin to a different one
--   02  NEGATIVE CONTROL: a card pinned to a version that sets NO reward expiry produces no
--       deadline at all and stays claimable — today's behaviour, which this migration must not
--       disturb. Against an unpatched database this suite cannot run (the objects do not exist),
--       which is itself the pre-apply result.
--   03  a card pinned to a version that DOES set one carries a real date, measured from the
--       moment the milestone was earned
--   04  NEVER RETROACTIVE: the version another customer's card is pinned to is untouched, so
--       their reward still has no deadline while the active version sets 30 days
--   05  an overdue reward is withdrawn on the READ path, before any sweep — customer and till
--       agree because both read app.reward_availability_v432 (the v432 invariant)
--   06  the counter refuses it, in a sentence a person can read
--   07  the sweep withdraws exactly the overdue one, once, with a customer History entry and an
--       owner audit row
--   08  CARD EXPIRY x REWARD EXPIRY: a reward with no deadline still survives its card lapsing
--       (protected v435 rule 4/5); a reward with a live deadline survives too, still carrying it
--   09  the owner write path stores the setting on a NEW version and mutates no existing one
--
-- THE TIME MACHINE. One transaction fixes now(), so the fixture is built with explicit
-- published_at values and backdated points_ledger.created_at rather than by letting real time
-- pass. Both are fixture-only devices and are marked at every use.

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v464_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v464_user(uuid) to public;

-- public.points_ledger is guarded: app.loyalty_ledger_write_guard refuses any append that does
-- not name its own row id and one of the eight sanctioned write scopes. The fixture goes through
-- the same door rather than around it. TIME MACHINE: p_at backdates the row.
create or replace function pg_temp.v464_ledger(
  p_biz uuid, p_client uuid, p_programme uuid, p_points integer, p_actor uuid, p_at timestamptz)
returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger(id, business_id, client_id, programme_id,
                                   entry_type, points, reference, actor, created_at)
  values (v_id, p_biz, p_client, p_programme, 'adjust', p_points,
          'v464 acceptance fixture', p_actor, p_at);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  insert into public.points_batches(business_id, client_id, programme_id, earned, remaining, earned_at)
  values (p_biz, p_client, p_programme, p_points, p_points, p_at);
end
$$;
grant execute on function pg_temp.v464_ledger(uuid, uuid, uuid, integer, uuid, timestamptz) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_spine uuid;
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v464-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_cfg1 uuid;                        -- published -300d : no reward expiry, no card validity
  v_cfg2 uuid := gen_random_uuid();   -- published -250d : card validity 15, no reward expiry
  v_cfg3 uuid := gen_random_uuid();   -- published -200d : card validity 15, reward expiry 30
  v_cust_c uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_client_a uuid := gen_random_uuid();  -- card at -280d -> cfg1 : no deadline, control
  v_client_b uuid := gen_random_uuid();  -- card at  -20d -> cfg3 : deadline +10d, live
  v_client_c uuid := gen_random_uuid();  -- card at  -60d -> cfg3 : deadline -30d, overdue
  v_client_d uuid := gen_random_uuid();  -- card at -230d -> cfg2 : no deadline, card lapsed
  v_free uuid := gen_random_uuid();      -- gift at stamp 3
  v_big  uuid := gen_random_uuid();      -- gift at stamp 5 (never earned: 4 stamps)
  v_row record; v_txt text; v_n integer; v_json jsonb; v_pin uuid; v_save jsonb;
  v_at timestamptz;
begin
  -- ==========================================================================================
  -- 01  FIXTURE
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V464 Acceptance', v_slug, array['loyalty'], 'redeem');
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
          'zz-v464-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_cust_c, 'authenticated', 'authenticated',
          'zz-v464-cust-' || substr(v_cust_c::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V464 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v464 acceptance',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;
  insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
  values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;
  -- Platform-wide flags: already on in production, asserted here so the suite is runnable
  -- anywhere. Rolled back with everything else.
  insert into app.platform_feature_flags(feature_key, enabled)
  values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
  on conflict (feature_key) do update set enabled = true;

  -- Back to the owner. BOTH GUCs: auth.uid() prefers request.jwt.claim.sub, which
  -- pg_temp.as_v464_user sets, so setting only the claims JSON leaves the customer in place.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, stamp_target, stamp_per_cents)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500)
  on conflict (business_id) do update
    set active = true, loyalty_model = 'stamps', kind = 'stamps',
        configuration_status = 'published', stamp_target = 5, stamp_per_cents = 500;
  -- Configuration versions are append-only, so the seed trigger's own published version is
  -- ADOPTED as version 1 rather than deleted, and the other two are appended beside it.
  select id into v_cfg1 from public.firm_config_versions
   where business_id = v_biz and status = 'published' order by version_no desc limit 1;
  -- TIME MACHINE: three published versions laid out on a timeline, so a backdated card pins to
  -- exactly the one this fixture intends. firm_config_versions is the header table the publish
  -- itself writes; only the typed rows beside it are append-only.
  update public.firm_config_versions
     set status = 'superseded', published_at = now() - interval '300 days',
         superseded_at = now() - interval '250 days'
   where id = v_cfg1;
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash,
                                          published_at, superseded_at)
  select v_cfg2, v_biz, coalesce(max(version_no), 0) + 1, 'superseded', md5('v464-2'),
         now() - interval '250 days', now() - interval '200 days'
    from public.firm_config_versions where business_id = v_biz;
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash, published_at)
  select v_cfg3, v_biz, coalesce(max(version_no), 0) + 1, 'published', md5('v464-3'), now() - interval '200 days'
    from public.firm_config_versions where business_id = v_biz;
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model,
    active, earn_points_per_dollar, redeem_points, reward_credit_cents,
    stamp_target, stamp_per_cents, tier_basis, expiry_mode, expiry_days,
    stamp_validity_days, stamp_reward_expiry_days)
  select cfg.id, business_id, kind, loyalty_model, active, earn_points_per_dollar, redeem_points,
         reward_credit_cents, stamp_target, stamp_per_cents, tier_basis, expiry_mode, expiry_days,
         15, cfg.reward_expiry
    from public.loyalty_program_versions base
   cross join (values (v_cfg2, null::integer), (v_cfg3, 30)) as cfg(id, reward_expiry)
   where base.config_version_id = v_cfg1 and base.business_id = v_biz;
  update public.businesses set active_config_version_id = v_cfg3 where id = v_biz;

  insert into public.clients(id, business_id, full_name, phone) values
    (v_client_a, v_biz, 'V464 A', '+65 9464 1001'),
    (v_client_b, v_biz, 'V464 B', '+65 9464 1002'),
    (v_client_c, v_biz, 'V464 C', '+65 9464 1003'),
    (v_client_d, v_biz, 'V464 D', '+65 9464 1004');
  insert into public.customer_identities(id, auth_user_id, status) values (v_identity, v_cust_c, 'active');
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v_link, v_biz, v_identity, v_cust_c, v_client_c, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values (v_free, v_biz, 'Free Kopi', 'Free Kopi', 'Free Kopi', 'manual_item', 3, 0, 0, true, false, 1, v_spine),
         (v_big,  v_biz, 'Big Gift',  'Big Gift',  'Big Gift',  'manual_item', 5, 0, 0, true, false, 2, v_spine);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, sort, programme_id)
  select r.id, v_biz, cfg.id, r.name, r.name, 'manual_item', r.cost, 0, 0, r.sort, v_spine
    from (values (v_free, 'Free Kopi', 3, 1), (v_big, 'Big Gift', 5, 2)) as r(id, name, cost, sort)
   cross join (values (v_cfg1), (v_cfg2), (v_cfg3)) as cfg(id);

  -- TIME MACHINE: four backdated cards, four stamps each.
  perform pg_temp.v464_ledger(v_biz, v_client_a, v_spine, 4, v_owner, now() - interval '280 days');
  perform pg_temp.v464_ledger(v_biz, v_client_d, v_spine, 4, v_owner, now() - interval '230 days');
  perform pg_temp.v464_ledger(v_biz, v_client_c, v_spine, 4, v_owner, now() - interval '60 days');
  perform pg_temp.v464_ledger(v_biz, v_client_b, v_spine, 4, v_owner, now() - interval '20 days');

  insert into _r values('01_pins',
    case when app.stamp_cycle_version_v416(v_biz, v_client_a, v_spine) = v_cfg1
          and app.stamp_cycle_version_v416(v_biz, v_client_d, v_spine) = v_cfg2
          and app.stamp_cycle_version_v416(v_biz, v_client_b, v_spine) = v_cfg3
          and app.stamp_cycle_version_v416(v_biz, v_client_c, v_spine) = v_cfg3
      then 'PASS four cards pinned to the three versions this fixture intends'
      else 'FAIL the fixture cards did not pin as intended' end);

  -- ==========================================================================================
  -- 02  NEGATIVE CONTROL — a version that sets nothing produces no deadline
  -- ==========================================================================================
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client_a, v_spine, 0, 3);
  insert into _r values('02_no_setting_no_deadline',
    case when v_row.earned_at is not null and v_row.expiry_days is null and v_row.expires_at is null
      then 'PASS the reward is earned and carries no deadline — unchanged behaviour'
      else 'FAIL earned_at=' || coalesce(v_row.earned_at::text, 'null')
           || ' days=' || coalesce(v_row.expiry_days::text, 'null')
           || ' expires=' || coalesce(v_row.expires_at::text, 'null') end);
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client_a, now()) core where core.reward_id = v_free;
  insert into _r values('02_no_setting_still_claimable',
    case when v_txt = 'available_at_counter' then 'PASS' else 'FAIL reads ' || coalesce(v_txt, 'null') end);

  -- ==========================================================================================
  -- 03  A REAL DATE, MEASURED FROM THE MOMENT IT WAS EARNED
  -- ==========================================================================================
  select * into v_row from app.stamp_reward_expiry_v464(v_biz, v_client_b, v_spine, 0, 3);
  insert into _r values('03_deadline_from_the_earn_moment',
    case when v_row.expiry_days = 30
          and v_row.expires_at between now() + interval '9 days' and now() + interval '11 days'
      then 'PASS earned 20 days ago, 30-day rule, due in ~10 days'
      else 'FAIL days=' || coalesce(v_row.expiry_days::text, 'null')
           || ' expires=' || coalesce(v_row.expires_at::text, 'null') end);
  select core.availability, core.reward_expires_at into v_txt, v_at
    from app.reward_availability_v432(v_biz, v_client_b, now()) core where core.reward_id = v_free;
  insert into _r values('03_inside_the_deadline_is_claimable',
    case when v_txt = 'available_at_counter' and v_at is not null then 'PASS'
         else 'FAIL reads ' || coalesce(v_txt, 'null') || ' / ' || coalesce(v_at::text, 'no date') end);

  -- ==========================================================================================
  -- 04  NEVER RETROACTIVE
  -- ==========================================================================================
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_cfg1 and business_id = v_biz;
  insert into _r values('04_the_older_version_was_not_rewritten',
    case when v_n is null then 'PASS the version customer A''s card is pinned to still sets nothing'
         else 'FAIL version 1 carries ' || v_n end);
  select count(*) into v_n from public.stamp_reward_expiries_v464
   where business_id = v_biz and client_id = v_client_a;
  insert into _r values('04_no_deadline_no_withdrawal_ever',
    case when v_n = 0 then 'PASS' else 'FAIL ' || v_n || ' withdrawal rows for a customer with no deadline' end);

  -- ==========================================================================================
  -- 05  OVERDUE IS WITHDRAWN ON THE READ PATH, BEFORE ANY SWEEP
  -- ==========================================================================================
  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client_c, now()) core where core.reward_id = v_free;
  insert into _r values('05_overdue_withdrawn_without_a_sweep',
    case when v_txt = 'reward_expired' then 'PASS'
         else 'FAIL reads ' || coalesce(v_txt, 'null') || ' (expected reward_expired)' end);

  perform pg_temp.as_v464_user(v_owner);
  v_json := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client_c, null);
  execute 'reset role';
  insert into _r values('05_the_till_stops_offering_it',
    case when not exists (select 1 from jsonb_array_elements(v_json -> 'rewards') as t(value)
                           where value ->> 'reward_id' = v_free::text)
      then 'PASS the counter is not offered a reward the wallet has withdrawn'
      else 'FAIL still listed: ' || (v_json -> 'rewards')::text end);

  perform pg_temp.as_v464_user(v_owner);
  v_json := public.staff_get_customer_actionable_loyalty_v145(v_biz, v_client_b, null);
  execute 'reset role';
  select value into v_json from jsonb_array_elements(v_json -> 'rewards') as t(value)
   where value ->> 'reward_id' = v_free::text;
  insert into _r values('05_the_till_carries_the_date',
    case when v_json is not null and v_json ->> 'expires_at' is not null
          and (v_json ->> 'available_now')::boolean
      then 'PASS the counter sees the live reward and the day it must be used by'
      else 'FAIL ' || coalesce(v_json::text, 'not listed') end);

  -- ==========================================================================================
  -- 06  THE COUNTER REFUSES IT, IN WORDS
  -- ==========================================================================================
  -- Back to the owner. BOTH GUCs: auth.uid() prefers request.jwt.claim.sub, which
  -- pg_temp.as_v464_user sets, so setting only the claims JSON leaves the customer in place.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    perform app.redeem_reward_core(v_biz, v_client_c, v_free, 'v464-acc-expired-01', v_branch, null, null);
    insert into _r values('06_counter_refuses_expired', 'FAIL the counter honoured an expired reward');
  exception when others then
    get stacked diagnostics v_txt = message_text;
    insert into _r values('06_counter_refuses_expired',
      case when position('expired' in lower(v_txt)) > 0
        then 'PASS "' || v_txt || '"'
        else 'FAIL refusal does not mention expiry: "' || v_txt || '"' end);
  end;

  -- ==========================================================================================
  -- 07  THE SWEEP — exactly the overdue one, once, with both trails
  -- ==========================================================================================
  select app.run_stamp_reward_expiry_for_business(v_biz) into v_n;
  insert into _r values('07_sweep_withdrew_exactly_one',
    case when v_n = 1 then 'PASS' else 'FAIL withdrew ' || v_n || ' (expected 1: customer C''s Free Kopi)' end);
  select count(*) into v_n from public.stamp_reward_expiries_v464
   where business_id = v_biz and reward_id = v_big;
  insert into _r values('07_unearned_milestone_untouched',
    case when v_n = 0 then 'PASS a milestone the customer never reached is not "lost"'
         else 'FAIL ' || v_n || ' rows for the unearned gift' end);
  select count(*) into v_n from public.audit_log
   where business_id = v_biz and action = 'stamp_reward.expired';
  insert into _r values('07_owner_trail',
    case when v_n = 1 then 'PASS' else 'FAIL ' || v_n || ' audit rows' end);
  select app.run_stamp_reward_expiry_for_business(v_biz) into v_n;
  insert into _r values('07_sweep_is_idempotent',
    case when v_n = 0 then 'PASS' else 'FAIL a second sweep withdrew ' || v_n || ' more' end);

  perform pg_temp.as_v464_user(v_cust_c);
  v_json := public.customer_get_reward_history_v422(v_slug, 50);
  execute 'reset role';
  insert into _r values('07_customer_history_entry',
    case when exists (select 1 from jsonb_array_elements(v_json -> 'items') as t(value)
                       where value ->> 'source' = 'expired'
                         and value ->> 'reward_name' = 'Free Kopi'
                         and value ->> 'expired_at' is not null)
      then 'PASS the customer can see what they lost, next to what they used'
      else 'FAIL ' || (v_json -> 'items')::text end);

  -- ==========================================================================================
  -- 08  CARD EXPIRY x REWARD EXPIRY — the protected v435 survival rule, intact
  -- ==========================================================================================
  -- Back to the owner. BOTH GUCs: auth.uid() prefers request.jwt.claim.sub, which
  -- pg_temp.as_v464_user sets, so setting only the claims JSON leaves the customer in place.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  select app.run_stamp_expiry_for_business(v_biz) into v_n;
  insert into _r values('08_card_sweep_closed_the_lapsed_cards',
    case when v_n >= 3 then 'PASS ' || v_n || ' cards lapsed on their own validity'
         else 'FAIL only ' || v_n || ' cards lapsed' end);

  select core.availability, core.reward_expires_at into v_txt, v_at
    from app.reward_availability_v432(v_biz, v_client_d, now()) core where core.reward_id = v_free;
  insert into _r values('08_no_deadline_survives_card_expiry',
    case when v_txt = 'available_at_counter' and v_at is null
      then 'PASS a reward with no deadline still outlives its card (v435 rule 4/5)'
      else 'FAIL reads ' || coalesce(v_txt, 'null') || ' / ' || coalesce(v_at::text, 'no date') end);

  select core.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client_b, now()) core where core.reward_id = v_free;
  insert into _r values('08_live_deadline_survives_card_expiry',
    case when v_txt = 'available_at_counter'
      then 'PASS a reward still inside its own deadline outlives its card too'
      else 'FAIL reads ' || coalesce(v_txt, 'null') end);
  v_json := app.redeem_reward_core(v_biz, v_client_b, v_free, 'v464-acc-survivor-01', v_branch, null, null)::jsonb;
  insert into _r values('08_survivor_with_a_deadline_is_honoured',
    case when coalesce((v_json ->> 'from_expired_card')::boolean, false)
      then 'PASS claimed from the lapsed card' else 'FAIL ' || v_json::text end);

  begin
    perform app.redeem_reward_core(v_biz, v_client_c, v_free, 'v464-acc-expired-02', v_branch, null, null);
    insert into _r values('08_expired_stays_expired_after_the_card_lapses',
      'FAIL survival handed over a reward the sweep had already withdrawn');
  exception when others then
    get stacked diagnostics v_txt = message_text;
    insert into _r values('08_expired_stays_expired_after_the_card_lapses',
      case when position('expired' in lower(v_txt)) > 0 then 'PASS "' || v_txt || '"'
           else 'FAIL "' || v_txt || '"' end);
  end;

  -- ==========================================================================================
  -- 09  THE OWNER WRITE PATH
  -- ==========================================================================================
  -- Back to the owner. BOTH GUCs: auth.uid() prefers request.jwt.claim.sub, which
  -- pg_temp.as_v464_user sets, so setting only the claims JSON leaves the customer in place.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_save := public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 45);
  select active_config_version_id into v_pin from public.businesses where id = v_biz;
  select stamp_reward_expiry_days into v_n from public.loyalty_program_versions
   where config_version_id = v_pin and business_id = v_biz;
  insert into _r values('09_saved_onto_a_new_version',
    case when v_pin <> v_cfg3 and v_n = 45
      then 'PASS 45 days written to a NEW version, not over the live one'
      else 'FAIL version=' || coalesce(v_pin::text, 'null') || ' days=' || coalesce(v_n::text, 'null') end);
  select count(*) into v_n from public.loyalty_program_versions
   where business_id = v_biz and config_version_id in (v_cfg1, v_cfg2, v_cfg3)
     and stamp_reward_expiry_days is distinct from
         (case config_version_id when v_cfg3 then 30 else null end);
  insert into _r values('09_existing_versions_untouched',
    case when v_n = 0 then 'PASS every version a customer''s card is pinned to is unchanged'
         else 'FAIL ' || v_n || ' existing versions were rewritten' end);
  select stamp_reward_expiry_days into v_n from public.loyalty_programs where business_id = v_biz;
  insert into _r values('09_display_mirror_follows_the_publish',
    case when v_n = 45 then 'PASS' else 'FAIL mirror reads ' || coalesce(v_n::text, 'null') end);
  begin
    perform public.business_set_earning_rule_v359(v_biz, null, null, null, null, null, 4000);
    insert into _r values('09_out_of_range_refused', 'FAIL 4000 days was accepted');
  exception when sqlstate '22023' then
    insert into _r values('09_out_of_range_refused', 'PASS');
  end;
end
$$;

reset role;
select k, v from _r order by k;

rollback;
