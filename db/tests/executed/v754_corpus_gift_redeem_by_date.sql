-- EXECUTED acceptance fixture for nestly_v754
-- (db/migrations/20260924_nestly_v754_gift_expiry_is_a_redeem_by_date.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v754_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-04 (batch 2 photo 1): a points gift's "Expires after" days
-- field must mean "after N days this gift can no longer be redeemed with points and disappears
-- from the customer's app" — a catalogue redeem-by DEADLINE — not the old nestly_v520 reading,
-- "days a customer has to use this gift once they take it" (a post-claim countdown). v754 teaches
-- business_create_reward_v326 / business_update_reward_v326 a new p_claim_expires_after_days
-- parameter that computes claim_available_until = this call's own now() + N days and pins it on
-- the published version, reusing the claim_available_until enforcement that nestly_v472/v89/v432
-- already ship everywhere a gift is read or redeemed.
--
-- ASSERTIONS:
--   E1  business_create_reward_v326(..., p_claim_expires_after_days:=90) pins a
--       claim_available_until on BOTH the live loyalty_rewards row and the published
--       loyalty_reward_versions row, within a few seconds of now()+90 days (the publish instant),
--       not recomputed from some other clock.
--   E2  the customer catalogue read (customer_get_reward_catalog) carries that same date and
--       still offers the gift before it.
--   E3  backdating the pinned date into the past (as the owner, the way v676's suite backdates a
--       row) makes the gift disappear from the customer catalogue read AND makes
--       customer_create_redemption_intent_v89 refuse it.
--   E4  the same backdated gift is refused by staff_manual_redeem_reward_v404 too (it calls
--       app.redeem_reward_core, which raises 'reward expired').
--   E5  a gift saved with the days field left blank has no end date at all, and stays offered.
--   E6  none of the above moved a single point in the customer's ledger balance.
--
-- MUTATION CHECK (documented, not re-run here): commenting out the
-- "now() + make_interval(days => p_claim_expires_after_days)" branch in
-- business_create_reward_v326 (so it falls through to p_claim_available_until, which the points
-- dialog never sends) turns E1 red — the created reward's claim_available_until comes back null
-- instead of ~90 days out — and E3/E4 lose their fixture (nothing to backdate), so the whole
-- suite goes red rather than silently passing on a no-op.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v754_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v754_user(uuid,text) to public;

do $v754_test$
declare
  v_business  uuid;
  v_slug      text;
  v_branch    uuid := gen_random_uuid();
  v_owner_u   uuid := gen_random_uuid();
  v_owner_s   uuid;
  v_customer  uuid := gen_random_uuid();
  v_identity  uuid;
  v_client    uuid;
  v_link      uuid := gen_random_uuid();
  v_prog      uuid;
  v_ver       uuid;
  v_out       jsonb;
  v_reward90  uuid;
  v_reward_blank uuid;
  v_row_until timestamptz;
  v_version_until timestamptz;
  v_expected_lo timestamptz;
  v_expected_hi timestamptz;
  v_catalog   jsonb;
  v_item      jsonb;
  v_balance_before integer;
  v_balance_after integer;
  v_seed_points_id uuid := gen_random_uuid();
  v_caught boolean;
begin
  reset role;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V754 gift expiry fixture',
    'v754-expiry-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty']
  ) returning id,slug into v_business,v_slug;
  perform set_config('app.v79_system_transition', '', true);

  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'V754 branch',true,true);

  insert into public.business_workspace_controls_v94
    (business_id,approval_status,decided_at,decision_reason)
  values(v_business,'approved',now(),'v754 fixture')
  on conflict (business_id) do update
    set approval_status='approved',decided_at=now(),decision_reason='v754 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_business,'current',false)
  on conflict (business_id) do update set state='current',workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active',payment_status='paid',current_period_end=now()+interval '30 days';

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet','customer_qr_redemption');

  -- The owner staff row: business_create_reward_v326 requires app.c45_owner_loyalty_write, and
  -- an owner may manual-redeem by role alone (nestly_v404 ruling), so one staff row covers both.
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner_u,'authenticated','authenticated',
    'v754-owner-' || substr(v_owner_u::text,1,8) || '@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  values(v_business,v_owner_u,'owner',true,'approved','V754 Owner')
  returning id into v_owner_s;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_owner_s,v_branch) on conflict do nothing;

  -- A published loyalty configuration: inserting the loyalty_programs row fires
  -- seed_loyalty_config_version(), the same one-insert trick nestly_v404's own suite uses,
  -- because business_create_reward_v326 refuses without a PUBLISHED firm_config_versions row.
  insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status,
    earn_points_per_dollar)
  values(v_business,'points',true,'classic','published',1);
  select id into v_ver from public.firm_config_versions
   where business_id=v_business and status='published' order by version_no desc limit 1;
  if v_ver is null then
    raise exception 'v754 fixture: no published config version was seeded';
  end if;
  update public.businesses set active_config_version_id=v_ver
   where id=v_business and active_config_version_id is null;

  insert into public.business_programmes(business_id,kind,active,sort,activated_at)
  values(v_business,'points',true,1,now())
  on conflict (business_id,kind) do update set active=true, activated_at=now()
  returning id into v_prog;

  -- The verified customer, so customer_get_reward_catalog and
  -- customer_create_redemption_intent_v89 both resolve identity.
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
    'v754-customer-' || substr(v_customer::text,1,8) || '@example.test','',now(),now(),now());
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer,'active','phone_registration')
  returning id into v_identity;
  insert into public.clients(business_id,full_name)
  values(v_business,'V754 verified customer') returning id into v_client;
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at)
  values(v_link,v_business,v_identity,v_customer,v_client,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- Seed 500 real points so E6 has a balance that could move if anything under test wrote to it.
  perform app.acquire_loyalty_shared_v480(v_business);
  perform set_config('app.points_ledger_insert_id',v_seed_points_id::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,programme_id,actor)
  values(v_seed_points_id,v_business,v_client,'adjust',500,'v754 fixture seed',v_prog,null);
  insert into public.points_batches(business_id,client_id,programme_id,remaining,earned,expires_at,earned_at)
  values(v_business,v_client,v_prog,500,500,null,now());
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);

  select coalesce(sum(points),0)::integer into v_balance_before
    from public.points_ledger where business_id=v_business and client_id=v_client;

  -- E1: create a gift with a 90-day redeem-by deadline.
  perform pg_temp.as_v754_user(v_owner_u); set local role authenticated;
  v_out := public.business_create_reward_v326(
    v_business, v_prog, 'V754 Ninety Day Gift', 10, 0, 'v754 fixture', null,
    null, null, null, 90);
  reset role;
  v_reward90 := (v_out->>'reward_id')::uuid;
  if v_reward90 is null then
    raise exception 'E1 setup: business_create_reward_v326 did not return a reward_id: %', v_out;
  end if;

  v_expected_lo := now() + interval '90 days' - interval '2 minutes';
  v_expected_hi := now() + interval '90 days' + interval '2 minutes';

  select claim_available_until into v_row_until
    from public.loyalty_rewards where id=v_reward90 and business_id=v_business;
  select claim_available_until into v_version_until
    from public.loyalty_reward_versions where reward_id=v_reward90 and business_id=v_business
     and config_version_id=v_ver;

  if v_row_until is null or v_row_until not between v_expected_lo and v_expected_hi then
    raise exception 'E1: live row claim_available_until % is not ~90 days from now', v_row_until;
  end if;
  if v_version_until is null or v_version_until not between v_expected_lo and v_expected_hi then
    raise exception 'E1: published version claim_available_until % is not ~90 days from now', v_version_until;
  end if;
  if v_row_until is distinct from v_version_until then
    raise exception 'E1: live row and published version disagree: % vs %', v_row_until, v_version_until;
  end if;
  if (v_out->>'claim_available_until')::timestamptz is distinct from v_row_until then
    raise exception 'E1: the RPC response did not echo the pinned date: %', v_out;
  end if;

  -- E2: the customer catalogue read carries the same date and offers the gift.
  perform pg_temp.as_v754_user(v_customer); set local role authenticated;
  v_catalog := public.customer_get_reward_catalog(v_slug);
  reset role;
  select value into v_item from jsonb_array_elements(v_catalog->'rewards') value
   where value->>'customer_name' = 'V754 Ninety Day Gift' limit 1;
  if v_item is null then
    raise exception 'E2: the 90-day gift was not offered in the customer catalogue: %', v_catalog;
  end if;
  if (v_item->>'claim_available_until')::timestamptz is distinct from v_row_until then
    raise exception 'E2: customer catalogue quoted a different date than the pinned one: % vs %',
      v_item->>'claim_available_until', v_row_until;
  end if;

  -- E3: backdate the pinned date, as the owner, on both rows (the way v676's suite inserts a
  -- backdated row rather than waiting for real time to pass).
  reset role;
  -- The published version row is immutable to an ordinary UPDATE (app.reward_version_immutable_
  -- guard) even for the table owner; session_replication_role=replica is the same "act as the
  -- owner, not through any RPC" bypass a backdated-row fixture needs, scoped to this one
  -- statement pair and reset immediately after.
  set local session_replication_role = replica;
  update public.loyalty_rewards set claim_available_until = now() - interval '1 day'
   where id=v_reward90 and business_id=v_business;
  update public.loyalty_reward_versions set claim_available_until = now() - interval '1 day'
   where reward_id=v_reward90 and business_id=v_business and config_version_id=v_ver;
  set local session_replication_role = origin;

  perform pg_temp.as_v754_user(v_customer); set local role authenticated;
  v_catalog := public.customer_get_reward_catalog(v_slug);
  reset role;
  select value into v_item from jsonb_array_elements(v_catalog->'rewards') value
   where value->>'customer_name' = 'V754 Ninety Day Gift' limit 1;
  if v_item is null then
    raise exception 'E3a setup: the backdated gift disappeared from the read entirely: %', v_catalog;
  end if;
  -- app.reward_availability_v432 (v432/v566) already reports 'ended' once claim_available_until
  -- has passed, and app/app.js's customerRewardCanRedeem (the ONE predicate the client's
  -- claimable list, hero swipe and ready-count all share) requires exactly
  -- availability='available_at_counter' — so 'ended' is precisely "not offered for redemption",
  -- the owner's own words. This asserts the SERVER's half of that contract.
  if v_item->>'availability' = 'available_at_counter' then
    raise exception 'E3a: an expired gift still reads as available_at_counter: %', v_item;
  end if;

  v_caught := false;
  perform pg_temp.as_v754_user(v_customer); set local role authenticated;
  begin
    perform public.customer_create_redemption_intent_v89(
      v_business, v_reward90, gen_random_uuid(), 'catalog_reward');
  exception when others then
    v_caught := true;
  end;
  reset role;
  if not v_caught then
    raise exception 'E3b: customer_create_redemption_intent_v89 accepted an expired gift';
  end if;

  -- E4: staff manual redemption refuses too (through app.redeem_reward_core).
  v_caught := false;
  perform pg_temp.as_v754_user(v_owner_u); set local role authenticated;
  begin
    perform public.staff_manual_redeem_reward_v404(
      v_business, v_client, v_reward90, 1, v_branch, 'customer_unable_to_show_qr', null,
      'zzv754-' || substr(md5(random()::text),1,8));
  exception when others then
    v_caught := true;
    if sqlerrm not ilike '%expired%' then
      raise exception 'E4: refused for the wrong reason: %', sqlerrm;
    end if;
  end;
  reset role;
  if not v_caught then
    raise exception 'E4: staff_manual_redeem_reward_v404 accepted an expired gift';
  end if;

  -- E5: a gift with no days is unaffected — no end date, still offered.
  perform pg_temp.as_v754_user(v_owner_u); set local role authenticated;
  v_out := public.business_create_reward_v326(
    v_business, v_prog, 'V754 No Expiry Gift', 10, 0, 'v754 fixture', null,
    null, null, null, null);
  reset role;
  v_reward_blank := (v_out->>'reward_id')::uuid;
  if exists(select 1 from public.loyalty_rewards
             where id=v_reward_blank and claim_available_until is not null)
     or exists(select 1 from public.loyalty_reward_versions
             where reward_id=v_reward_blank and config_version_id=v_ver
               and claim_available_until is not null) then
    raise exception 'E5: a blank days field still produced an end date';
  end if;
  perform pg_temp.as_v754_user(v_customer); set local role authenticated;
  v_catalog := public.customer_get_reward_catalog(v_slug);
  reset role;
  if not exists(select 1 from jsonb_array_elements(v_catalog->'rewards') value
                 where value->>'customer_name' = 'V754 No Expiry Gift') then
    raise exception 'E5: the no-expiry gift was not offered: %', v_catalog;
  end if;

  -- E6: none of the above moved a point.
  select coalesce(sum(points),0)::integer into v_balance_after
    from public.points_ledger where business_id=v_business and client_id=v_client;
  if v_balance_after is distinct from v_balance_before then
    raise exception 'E6: the balance moved from % to % without a successful redemption',
      v_balance_before, v_balance_after;
  end if;

  raise notice 'v754_corpus: all assertions passed (E1-E6)';
end
$v754_test$;

rollback;
