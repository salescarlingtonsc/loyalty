-- EXECUTED baseline behaviours for the Rewards engine — the regression floor.
--
-- WHY THIS FILE EXISTS
-- Every other file in db/tests/executed/ proves one migration did what it said. This one
-- proves the things that were ALREADY true stay true. It is pinned to no version: it must
-- pass against the frozen baseline (tests/fixtures/db-schema-snapshot.sql, v422) AND against
-- that baseline with every pending migration applied. `npm run test:db` runs it in both
-- phases for exactly that reason.
--
-- It exists because a mutation test in August 2026 planted two real Rewards defects and the
-- 3297-test suite stayed green: `npm test` executed no SQL at all, and the 334 files under
-- db/tests/ were only ever read by regex. Nothing here is stubbed — real triggers, real RPCs,
-- real constraints, on real Postgres.
--
-- WHAT IT COVERS (each assertion names itself in its failure message)
--   A1  earning on a sale writes exactly one points_ledger row and one points_batches row
--   A2  both carry the programme the points belong to (the v312/v381 pot-scoping invariant)
--   A3  a second sale earns again — the guard in A1 is "not duplicated", not "only ever one"
--   A4  redeeming a reward debits the balance and records one redemption
--   A5  redeeming beyond the balance is refused, and refuses without debiting
--   A6  replaying a redemption with the same idempotency key does not debit twice
--   A7  a stamp milestone cannot be claimed twice for the same cycle and slot
--   A8  joining twice mints exactly one welcome-offer grant
--
-- HONEST LIMITS. A7 asserts the uniqueness invariant directly against the claims table rather
-- than by driving a full stamp programme through the till, because standing up a published
-- stamp configuration is a fixture an order of magnitude larger than the invariant it would
-- prove. If a stamp end-to-end suite lands later, this assertion should fold into it.
--
-- The whole file is one transaction and rolls back. Failures RAISE.

\set ON_ERROR_STOP on

begin;

do $baseline$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_other_client uuid := gen_random_uuid();
  v_cfg uuid := gen_random_uuid();
  v_slug text := 'zz-v422-baseline-' || substr(gen_random_uuid()::text, 1, 8);
  v_points_pot uuid;
  v_stamp_pot uuid;
  v_reward uuid := gen_random_uuid();
  v_reward_version uuid := gen_random_uuid();
  v_dear_reward uuid := gen_random_uuid();
  v_dear_version uuid := gen_random_uuid();
  v_sale_a uuid := gen_random_uuid();
  v_sale_b uuid := gen_random_uuid();
  v_idem text := 'v422-redeem-' || substr(gen_random_uuid()::text, 1, 12);
  v_n integer;
  v_balance integer;
  v_batch_balance integer;
  v_prog uuid;
  v_before integer;
  v_redemption_a uuid;
  v_redemption_b uuid;
  v_redemption_c uuid;
begin
  -- ==========================================================================================
  -- FIXTURE — one firm, one owner, one published points configuration, one customer
  -- ==========================================================================================
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v422-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '',
          now(), now(), now());

  insert into public.businesses(id, name, slug, industry, is_synthetic, enabled_modules)
  values (v_biz, 'ZZ v422 baseline fixture', v_slug, 'test', true,
          array['dashboard', 'clients', 'sales', 'loyalty', 'retention']);

  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'ZZ v422 owner', true);

  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v422 main', true, true);

  /* The workspace gate (v94) refuses every module write until the workspace is approved and
     not paused. Without these two the fixture fails with branch_module_access_required, which
     reads like a Rewards bug and is not one. */
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v422 baseline fixture',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  -- Act as the owner from here on: every RPC below resolves the caller through auth.uid().
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- Publish a points configuration. Loyalty config is versioned and immutable once published,
  -- so the draft is written first and the version row is flipped afterwards.
  insert into public.firm_config_versions(id, business_id, version_no, status, source,
                                          snapshot_hash, created_by)
  values (v_cfg, v_biz, 1, 'draft', 'manual', md5('v422-baseline'), v_owner);
  insert into public.loyalty_program_versions(
    config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_cfg, v_biz, 'points', 'points_tiers', true, 1, 150, 0, 'points_earned', 'none');
  update public.firm_config_versions
     set status = 'published', published_at = clock_timestamp()
   where id = v_cfg;
  insert into public.loyalty_programs(business_id, kind, active, loyalty_model,
                                      configuration_status, current_config_version_id)
  values (v_biz, 'points', true, 'points_tiers', 'published', v_cfg);
  perform set_config('app.v79_system_transition', 'on', true);
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;
  perform set_config('app.v79_system_transition', '', true);

  /* The programme spine rows are created for the firm automatically. Read them — inserting
     would collide with business_programmes_business_id_kind_key. */
  select spine.id into v_points_pot
    from public.business_programmes spine
   where spine.business_id = v_biz and spine.kind = 'points';
  if v_points_pot is null then
    raise exception 'v422 fixture: no points pot on the programme spine for this firm';
  end if;
  update public.business_programmes set active = true
   where business_id = v_biz and kind = 'points';
  select spine.id into v_stamp_pot
    from public.business_programmes spine
   where spine.business_id = v_biz and spine.kind = 'stamps';

  insert into public.clients(id, business_id, full_name)
  values (v_client, v_biz, 'ZZ v422 customer'),
         (v_other_client, v_biz, 'ZZ v422 second customer');

  -- ==========================================================================================
  -- A1/A2  EARNING — one ledger row, one batch row, both scoped to the points pot
  -- ==========================================================================================
  insert into public.sales(id, business_id, client_id, kind, amount_cents, branch_id)
  values (v_sale_a, v_biz, v_client, 'service', 10000, v_branch);

  select count(*) into v_n from public.points_ledger
   where business_id = v_biz and sale_id = v_sale_a and entry_type = 'earn';
  if v_n <> 1 then
    raise exception 'v422 A1: a $100 service sale wrote % earn ledger row(s), expected exactly 1', v_n;
  end if;

  select count(*) into v_n from public.points_batches
   where business_id = v_biz and sale_id = v_sale_a;
  if v_n <> 1 then
    raise exception 'v422 A1: a $100 service sale wrote % points batch(es), expected exactly 1', v_n;
  end if;

  /* v312/v381: points belong to a pot. An unscoped write is the defect that made a customer
     see 97 points while the till showed 855 — the readers were summing every pot. */
  select programme_id into v_prog from public.points_ledger
   where business_id = v_biz and sale_id = v_sale_a and entry_type = 'earn';
  if v_prog is distinct from v_points_pot then
    raise exception 'v422 A2: earn ledger row is scoped to programme %, expected the points pot %',
      coalesce(v_prog::text, 'null'), v_points_pot;
  end if;
  select programme_id into v_prog from public.points_batches
   where business_id = v_biz and sale_id = v_sale_a;
  if v_prog is distinct from v_points_pot then
    raise exception 'v422 A2: points batch is scoped to programme %, expected the points pot %',
      coalesce(v_prog::text, 'null'), v_points_pot;
  end if;

  select coalesce(sum(points), 0)::integer into v_balance from public.points_ledger
   where business_id = v_biz and client_id = v_client;
  if v_balance <> 100 then
    raise exception 'v422 A1: $100 at 1 point per dollar earned % points, expected 100', v_balance;
  end if;

  -- A3  a SECOND sale earns again. A1 asserts "not duplicated"; without this, a mutation that
  --     made the trigger fire only once per client would slip through A1 untouched.
  insert into public.sales(id, business_id, client_id, kind, amount_cents, branch_id)
  values (v_sale_b, v_biz, v_client, 'service', 5000, v_branch);
  select coalesce(sum(points), 0)::integer into v_balance from public.points_ledger
   where business_id = v_biz and client_id = v_client;
  if v_balance <> 150 then
    raise exception 'v422 A3: after a second $50 sale the balance is %, expected 150', v_balance;
  end if;
  select count(*) into v_n from public.points_batches
   where business_id = v_biz and client_id = v_client;
  if v_n <> 2 then
    raise exception 'v422 A3: two sales produced % points batch(es), expected 2', v_n;
  end if;

  -- ==========================================================================================
  -- A4  REDEMPTION debits the balance and records exactly one redemption
  -- ==========================================================================================
  /* fulfillment_kind='manual_item' with credit_cents=0 is the shape the fulfillment_amount
     check allows for a non-credit gift; 'credit' would require credit_cents > 0. */
  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
                                     fulfillment_kind, estimated_cost_cents,
                                     cost_points, credit_cents, active,
                                     programme_id, current_config_version_id)
  values (v_reward, v_biz, 'ZZ v422 free coffee', 'ZZ v422 free coffee', 'ZZ v422 free coffee',
          'manual_item', 0, 120, 0, true, v_points_pot, v_cfg);
  insert into public.loyalty_reward_versions(
    id, config_version_id, business_id, reward_id, internal_name, customer_name,
    fulfillment_kind, estimated_cost_cents, cost_points, credit_cents, active, programme_id)
  values (v_reward_version, v_cfg, v_biz, v_reward, 'ZZ v422 free coffee', 'ZZ v422 free coffee',
          'manual_item', 0, 120, 0, true, v_points_pot);

  /* redeem_reward_at_context, not redeem_reward: the BEFORE INSERT guard on
     loyalty_redemptions reads the branch out of eligibility_snapshot->selected->branch_id and
     raises active_branch_required when it is absent, so the no-branch wrapper cannot be used
     by an ordinary authenticated caller at all. */
  perform public.redeem_reward_at_context(v_biz, v_client, v_reward, v_idem, v_branch, null, null);

  select count(*) into v_n from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client and reward_id = v_reward;
  if v_n <> 1 then
    raise exception 'v422 A4: redeeming once wrote % redemption row(s), expected 1', v_n;
  end if;
  select coalesce(sum(points), 0)::integer into v_balance from public.points_ledger
   where business_id = v_biz and client_id = v_client;
  if v_balance <> 30 then
    raise exception 'v422 A4: 150 points minus a 120-point reward left %, expected 30', v_balance;
  end if;
  /* The ledger and the batches are two separate records of the same truth. A redemption that
     debits one and not the other reads as correct on the customer's screen and wrong at the
     till — the exact shape of the pot-scoping defect this suite exists to catch. */
  select coalesce(sum(remaining), 0)::integer into v_batch_balance from public.points_batches
   where business_id = v_biz and client_id = v_client and programme_id = v_points_pot;
  if v_batch_balance <> 30 then
    raise exception 'v422 A4: batch remaining is % after a 120-point redemption, expected 30',
      v_batch_balance;
  end if;

  -- ==========================================================================================
  -- A5  REDEMPTION BEYOND THE BALANCE is refused, and refuses without debiting
  -- ==========================================================================================
  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
                                     fulfillment_kind, estimated_cost_cents,
                                     cost_points, credit_cents, active,
                                     programme_id, current_config_version_id)
  values (v_dear_reward, v_biz, 'ZZ v422 spa day', 'ZZ v422 spa day', 'ZZ v422 spa day',
          'manual_item', 0, 5000, 0, true, v_points_pot, v_cfg);
  insert into public.loyalty_reward_versions(
    id, config_version_id, business_id, reward_id, internal_name, customer_name,
    fulfillment_kind, estimated_cost_cents, cost_points, credit_cents, active, programme_id)
  values (v_dear_version, v_cfg, v_biz, v_dear_reward, 'ZZ v422 spa day', 'ZZ v422 spa day',
          'manual_item', 0, 5000, 0, true, v_points_pot);

  v_before := v_balance;
  begin
    perform public.redeem_reward_at_context(v_biz, v_client, v_dear_reward,
      'v422-overdraw-' || substr(gen_random_uuid()::text, 1, 12), v_branch, null, null);
    raise exception 'v422 A5: a 5000-point reward was redeemed against a 30-point balance';
  exception
    when check_violation then
      null;  -- expected: "insufficient proven points"
  end;

  select coalesce(sum(points), 0)::integer into v_balance from public.points_ledger
   where business_id = v_biz and client_id = v_client;
  if v_balance <> v_before then
    raise exception 'v422 A5: a refused redemption still moved the balance from % to %',
      v_before, v_balance;
  end if;
  select count(*) into v_n from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client and reward_id = v_dear_reward;
  if v_n <> 0 then
    raise exception 'v422 A5: a refused redemption left % redemption row(s) behind', v_n;
  end if;

  -- ==========================================================================================
  -- A6  IDEMPOTENCY — replaying the same key does not debit twice
  -- ==========================================================================================
  v_before := v_balance;
  perform public.redeem_reward_at_context(v_biz, v_client, v_reward, v_idem, v_branch, null, null);

  select count(*) into v_n from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client and reward_id = v_reward;
  if v_n <> 1 then
    raise exception 'v422 A6: replaying idempotency key % produced % redemption row(s), expected 1',
      v_idem, v_n;
  end if;
  select coalesce(sum(points), 0)::integer into v_balance from public.points_ledger
   where business_id = v_biz and client_id = v_client;
  if v_balance <> v_before then
    raise exception 'v422 A6: replaying idempotency key % debited again (% -> %)',
      v_idem, v_before, v_balance;
  end if;

  -- ==========================================================================================
  -- A7  STAMP MILESTONE — one claim per cycle and slot
  --
  -- A milestone claim must point at a real redemption (redemption_id is NOT NULL and unique),
  -- so the three rows below are backed by three real redemptions rather than hand-built rows.
  -- Top the balance up first: the client is down to 30 points after A4.
  -- ==========================================================================================
  if v_stamp_pot is null then
    raise exception 'v422 A7: this firm has no stamps pot on the spine — the fixture assumption '
      'that a firm gets one programme row per kind no longer holds';
  end if;

  insert into public.sales(id, business_id, client_id, kind, amount_cents, branch_id)
  values (gen_random_uuid(), v_biz, v_client, 'service', 50000, v_branch);

  perform public.redeem_reward_at_context(v_biz, v_client, v_reward,
    'v422-stamp-a-' || substr(gen_random_uuid()::text, 1, 12), v_branch, null, null);
  select id into v_redemption_a from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client order by redeemed_at desc, id desc limit 1;
  perform public.redeem_reward_at_context(v_biz, v_client, v_reward,
    'v422-stamp-b-' || substr(gen_random_uuid()::text, 1, 12), v_branch, null, null);
  select id into v_redemption_b from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client
     and id is distinct from v_redemption_a order by redeemed_at desc, id desc limit 1;
  perform public.redeem_reward_at_context(v_biz, v_client, v_reward,
    'v422-stamp-c-' || substr(gen_random_uuid()::text, 1, 12), v_branch, null, null);
  select id into v_redemption_c from public.loyalty_redemptions
   where business_id = v_biz and client_id = v_client
     and id is distinct from v_redemption_a and id is distinct from v_redemption_b
   order by redeemed_at desc, id desc limit 1;
  if v_redemption_a is null or v_redemption_b is null or v_redemption_c is null then
    raise exception 'v422 A7 fixture: expected three distinct redemptions, got % / % / %',
      v_redemption_a, v_redemption_b, v_redemption_c;
  end if;

  insert into public.stamp_milestone_claims(
    business_id, programme_id, client_id, cycle_index, slot_position, reward_id,
    reward_version_id, redemption_id, config_version_id, is_final)
  values (v_biz, v_stamp_pot, v_client, 1, 3, v_reward, v_reward_version, v_redemption_a,
          v_cfg, false);

  begin
    insert into public.stamp_milestone_claims(
      business_id, programme_id, client_id, cycle_index, slot_position, reward_id,
      reward_version_id, redemption_id, config_version_id, is_final)
    values (v_biz, v_stamp_pot, v_client, 1, 3, v_reward, v_reward_version, v_redemption_b,
            v_cfg, false);
    raise exception
      'v422 A7: slot 3 of cycle 1 was claimed twice — the milestone uniqueness key is gone';
  exception
    when unique_violation then
      null;  -- expected: stamp_milestone_claims_slot_uk
  end;

  -- The key is per cycle: the same slot in the NEXT cycle is a different claim, and must work.
  insert into public.stamp_milestone_claims(
    business_id, programme_id, client_id, cycle_index, slot_position, reward_id,
    reward_version_id, redemption_id, config_version_id, is_final)
  values (v_biz, v_stamp_pot, v_client, 2, 3, v_reward, v_reward_version, v_redemption_c,
          v_cfg, false);

  select count(*) into v_n from public.stamp_milestone_claims
   where business_id = v_biz and client_id = v_client and programme_id = v_stamp_pot;
  if v_n <> 2 then
    raise exception 'v422 A7: expected 2 milestone claims across two cycles, found %', v_n;
  end if;

  -- ==========================================================================================
  -- A8  WELCOME OFFER — joining twice mints one grant
  -- ==========================================================================================
  perform public.business_set_welcome_offer_v215(v_biz, true, 2000, 'custom', null, 30,
    'ZZ v422 welcome drink');
  perform app.issue_welcome_offer_v215(v_biz, v_other_client);
  perform app.issue_welcome_offer_v215(v_biz, v_other_client);

  select count(*) into v_n from public.welcome_offer_grants_v215
   where business_id = v_biz and client_id = v_other_client;
  if v_n <> 1 then
    raise exception 'v422 A8: issuing the welcome offer twice minted % grant(s), expected 1', v_n;
  end if;

  raise notice 'v422 baseline behaviours: A1-A8 all passed';
end
$baseline$;

rollback;
