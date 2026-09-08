-- NESTLY v845 — the customer's Stamp Card page stops disagreeing with every other reward reader.
--
-- WHY. public.customer_get_stamp_card_v323(text) is the ONLY reader behind the customer's Stamp
-- Card screen. app.reward_availability_v432 (the counter and the reward pages),
-- app.customer_ready_reward_count_v465 (the home tile) and public.customer_get_reward_catalog all
-- agree with each other about which gifts a customer holds. This one did not, in three separate
-- ways, all three observed against production on 2026-09-09 in rolled-back probes:
--
-- (A) A FULL CARD ON A STOPPED PROGRAMME READ "READY". The milestone CASE asked
--     `filled >= cost_points -> available_at_counter` BEFORE `not programme_active -> paused`, so
--     switching the stamps programme off did not take the gift off the card. Production, tenant
--     kopi-tiam-tyeh (business 8492e8d6-…, stamps spine 708d5047-… inactive), client
--     268cb96d-… holding 791 stamps on a 15-slot card: the card returned running=false and yet
--     milestones [Free Lotion=available_at_counter, Free Massage Oil=available_at_counter]
--     (reward ids 0558d355-… and 430e4bad-…), while app.reward_availability_v432 for the same
--     pair listed FOUR rows, none of them those two — its `where rows.programme_active` filter
--     (nestly_v495) drops a stopped programme's gifts outright. Same shape at hougang-abc-ts3u
--     (client 6dc64db0-…, "A thank-you on your next visits" = available_at_counter on a stopped
--     spine). Production is carrying 22 inactive stamp spines and 5 live gifts across them.
--     Note the branch already existed and already worked for a PARTLY filled card — the estate
--     shows kopi-tiam-tyeh's 3-of-5 client and kky-demo's 4-of-5 client reading 'paused'
--     correctly. Only the completed card fell through, which is exactly the case that matters.
--
-- (B) NO SURVIVOR ARM. When a card completes and rolls over (app.stamp_complete_full_cycle_v489),
--     the gifts earned on the finished cycle survive: nestly_v489/v496 gave
--     app.reward_availability_v432 a second arm reading public.stamp_cycles, and
--     app.customer_ready_reward_count_v465 and public.customer_get_reward_catalog inherit it.
--     customer_get_stamp_card_v323 never got one — it builds milestones solely from the OPEN
--     cycle (v_progress.filled / v_progress.cycle_index). Production, qa-kaya-toast (business
--     38b30e6d-…), client 49b43e01-… with 12 closed cycles: v432 offers ABC / Jffjj / Free Facial
--     Cream at quantity 12 each — 36 ready, which is the number the home tile prints — while the
--     card returned filled 0, carried 0, and all three milestones 'insufficient_stamps' with
--     "5 stamps to go". The customer was told to start collecting for gifts they had already won.
--
-- (C) next_milestone ADVERTISED AN UNCLAIMABLE GIFT. The subquery ordered by slot and filtered on
--     claimed_this_cycle alone, ignoring the availability it had just computed one line above.
--     Production, qa-kopi-lab (business 8ad4a375-…), client 07fd0757-…: next_milestone was
--     "Hava a cup of Milk Tea!" at slot 4 with availability 'ended' — its claim window closed
--     2026-08-24 15:59:59.999+00 — and the page therefore said "4 stamps to go" for a gift
--     app.reward_availability_v432 correctly reports as 'ended'.
--
-- WHAT THIS DOES. Three extract-and-diff splices on public.customer_get_stamp_card_v323(text),
-- applied to the LIVE body read with pg_get_functiondef, each anchored on text that must appear
-- exactly once or the migration refuses:
--   1. the 'paused' branch is asked before 'available_at_counter' (A);
--   2. a survivor block, mirroring arm 1 of app.reward_availability_v432 line for line, fills a
--      new `carried_rewards` array plus a `carried_rewards_ready` count (B);
--   3. next_milestone takes only a milestone whose availability is still reachable (C).
--
-- WHAT IT DOES NOT TOUCH.
--   * app.redeem_reward_core — the counter half of (A) is a SEPARATE migration by another agent.
--     Not one byte of it is read or written here.
--   * app.reward_availability_v432, app.customer_ready_reward_count_v465,
--     public.customer_get_reward_catalog — this migration makes the stamp card AGREE with them;
--     it does not restate, widen or second-guess their definition of what survives. The survivor
--     block is a transcription of arm 1: same source (public.stamp_cycles with
--     origin in ('expired','claimed','completed')), same version join
--     (rv.config_version_id = sc.config_version_id and rv.cost_points <= sc.slots), same live-row
--     predicates (app.reward_live_on_offer_v805 / app.reward_pause_on_offer_v814), the same
--     nestly_v568 pot fence (live.programme_id = sc.programme_id), the same not-yet-claimed test
--     against public.stamp_milestone_claims, and the same availability ladder.
--   * The `milestones` array's contents, order and shape. Survivors do NOT go into it. That array
--     is the CURRENT card's grid — app/app.js maps it by `slot` into the ring row — and a
--     survivor from a closed cycle carries its own cycle's slot, which would land a second crown
--     on a slot the customer has not reached. Survivors get their own key instead.
--   * The three existing payload keys `carried` (carried-over STAMPS), `ready` and `cycle_index`.
--     `carried_rewards` is a different fact with a deliberately adjacent name.
--   * Any refusal, guard, permission check or RLS policy. The ACLs are restated below exactly as
--     production holds them (postgres/service_role/authenticated execute; nothing for anon).
--
-- ONE DELIBERATE, DOCUMENTED DIVERGENCE FROM v432. On a STOPPED stamps programme v432 emits no
-- survivor row at all. This reader keeps the row and marks it 'paused', for the same reason it
-- keeps a stopped card's own milestones rather than blanking the card: the customer must be able
-- to see that the gift exists and is not currently claimable. The COUNTS still agree, because
-- 'paused' is never 'available_at_counter' and `carried_rewards_ready` counts only the latter —
-- a stopped programme reports zero ready on both readers.
--
-- ACCEPTANCE: db/tests/v845_stamp_card_reader_truth.sql
--             (executed copy db/tests/executed/v845_stamp_card_reader_truth.sql)
--   LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v845

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1. PRE-FLIGHT — the live body must be the one this file was written against.
--    Every anchor below is comment-free and must match EXACTLY once. If production has drifted
--    (another migration re-shaped the CASE, the return object or the declare block), this
--    refuses rather than splicing into a body it does not recognise.
-- ============================================================================================
do $v845_preflight$
declare
  v_def text;
  v_hits integer;
  v_anchor text;
  v_name text;
  v_anchors constant text[] := array[
'  v_spend_per_cents integer; -- nestly_v435
begin',
'      when v_progress.filled >= rung.cost_points then ''available_at_counter''
      when not v_progress.programme_active then ''paused''
      else ''insufficient_stamps''',
'  ) rung;

  return jsonb_build_object(
    ''enabled'', true,',
'    ''milestones'', v_milestones,
    ''next_milestone'', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> ''claimed_this_cycle'')::boolean is not true
       order by (rung.value ->> ''slot'')::integer
       limit 1)
  );'
  ];
  v_names constant text[] := array['declare block', 'availability CASE',
                                   'milestone query tail', 'return object tail'];
begin
  v_def := pg_get_functiondef('public.customer_get_stamp_card_v323(text)'::regprocedure);

  if position('nestly_v845' in v_def) > 0 then
    raise notice 'nestly_v845: customer_get_stamp_card_v323 already carries the v845 splices, '
                 'anchor pre-flight skipped';
  else
    for i in 1 .. array_length(v_anchors, 1) loop
      v_anchor := v_anchors[i];
      v_name := v_names[i];
      v_hits := (length(v_def) - length(replace(v_def, v_anchor, '')))
                / nullif(length(v_anchor), 0);
      if v_hits is distinct from 1 then
        raise exception 'nestly_v845 pre-flight: the % anchor matched % time(s) in '
                        'public.customer_get_stamp_card_v323 (expected exactly 1) — the live '
                        'body has drifted from the one this migration was written against',
          v_name, coalesce(v_hits, 0)
          using errcode = 'XX001';
      end if;
    end loop;
  end if;

  -- The three functions the survivor block transcribes must exist with the signatures it calls,
  -- or the spliced body would only fail at run time, on a customer's page.
  perform 'app.reward_live_on_offer_v805(boolean,timestamp with time zone,boolean)'::regprocedure;
  perform 'app.reward_pause_on_offer_v814(boolean,boolean,boolean)'::regprocedure;
  perform 'app.stamp_reward_expiry_v464(uuid,uuid,uuid,integer,integer)'::regprocedure;
  perform 'app.v176_reward_gate_threshold(uuid,uuid,integer)'::regprocedure;

  -- And arm 1 of v432 — the definition being mirrored — must still be the one that was read.
  v_def := pg_get_functiondef('app.reward_availability_v432(uuid,uuid,timestamp with time zone)'::regprocedure);
  if position('sc.origin in (''expired'',''claimed'',''completed'')' in v_def) = 0
     or position('live.programme_id = sc.programme_id' in v_def) = 0 then
    raise exception 'nestly_v845 pre-flight: app.reward_availability_v432 no longer carries the '
                    'survivor arm this migration transcribes — do not splice a stale copy of it '
                    'into the stamp card'
      using errcode = 'XX001';
  end if;

  raise notice 'nestly_v845 pre-flight ok: 4 anchors matched once each; the v432 survivor arm is intact';
end
$v845_preflight$;

-- ============================================================================================
-- 2. THE SPLICES.
-- ============================================================================================
do $v845_splice$
declare
  v_def text;
  v_new text;

  -- (B) a place to put the survivors.
  v_declare constant text :=
'  v_spend_per_cents integer; -- nestly_v435
begin';
  v_declare_new constant text :=
'  v_spend_per_cents integer; -- nestly_v435
  v_carried jsonb; -- nestly_v845
begin';

  -- (A) ask "is this programme still running?" BEFORE "is the card full?".
  v_case constant text :=
'      when v_progress.filled >= rung.cost_points then ''available_at_counter''
      when not v_progress.programme_active then ''paused''
      else ''insufficient_stamps''';
  v_case_new constant text :=
'      /* nestly_v845: ''paused'' is asked BEFORE ''available_at_counter''. In the old order a
         card whose stamps were already collected read READY on a programme the owner had
         switched OFF, while app.reward_availability_v432 dropped that gift outright
         (nestly_v495) — the card promised what the counter refuses. A partly filled card
         already answered ''paused'' correctly; only the completed one fell through. */
      when not v_progress.programme_active then ''paused''
      when v_progress.filled >= rung.cost_points then ''available_at_counter''
      else ''insufficient_stamps''';

  -- (B) the survivor block, between the milestone query and the payload.
  v_tail constant text :=
'  ) rung;

  return jsonb_build_object(
    ''enabled'', true,';
  v_tail_new constant text :=
'  ) rung;

  /* nestly_v845 — THE SURVIVOR ARM, transcribed from arm 1 of app.reward_availability_v432.
     A card that fills up is CLOSED by app.stamp_complete_full_cycle_v489 and a fresh one starts;
     the gifts earned on the finished cycle are not lost, they wait at the counter until they are
     claimed or they expire. Every other reader has known this since nestly_v489/v496 — v432, the
     home tile''s app.customer_ready_reward_count_v465 and public.customer_get_reward_catalog —
     and this reader did not, so a customer at qa-kaya-toast was told "5 stamps to go" for gifts
     the home tile was counting as 36 already won.

     This is a TRANSCRIPTION, not a second opinion. Source, version join, live-row predicates, the
     nestly_v568 pot fence and the not-yet-claimed test are arm 1''s, unchanged. Two differences,
     both deliberate:
       * survivors are NOT merged into `milestones`. That array is the CURRENT card''s grid and
         the client maps it by `slot`; a survivor carries the slot it had on ITS OWN cycle, which
         would draw a crown on a slot this customer has not reached. They get their own key.
       * v432 drops every row when the stamps programme is switched off; this reader keeps the
         row and says ''paused'', exactly as it keeps a stopped card''s own milestones. The counts
         still agree: ''paused'' is not ''available_at_counter'', so carried_rewards_ready is 0 on
         a stopped programme, which is what v432 offers. */
  select coalesce(jsonb_agg(jsonb_build_object(
    ''reward_id'', carry.reward_id,
    ''name'', carry.customer_name,
    ''slot'', carry.cost_points,
    ''is_final'', carry.cost_points >= carry.cycle_slots,
    ''claimed_this_cycle'', false,
    ''description'', carry.description,
    ''image_ref'', carry.image_ref,
    ''terms'', carry.terms,
    ''instructions'', carry.instructions,
    ''availability'', carry.availability,
    ''stamps_to_go'', 0,
    ''expires_at'', carry.reward_expires_at,
    ''cycle_index'', carry.cycle_index
  ) order by carry.cycle_index, carry.cost_points, carry.customer_name), ''[]''::jsonb)
  into v_carried
  from (
    select sc.cycle_index, sc.slots as cycle_slots,
           rv.reward_id, rv.customer_name, rv.cost_points, rv.description, rv.image_ref,
           rv.terms, rv.instructions, expiry.expires_at as reward_expires_at,
           case
             when rv.claim_available_from is not null and now() < rv.claim_available_from
               then ''not_started''
             when rv.claim_available_until is not null and now() >= rv.claim_available_until
               then ''ended''
             when gate.threshold is not null and v_metric < gate.threshold then ''tier_locked''
             when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
               then ''limit_reached''
             when expiry.recorded
                  or (expiry.expires_at is not null and expiry.expires_at <= now())
               then ''reward_expired''
             when not v_progress.programme_active then ''paused''
             else ''available_at_counter''
           end as availability
      from public.stamp_cycles sc
      join public.loyalty_reward_versions rv
        on rv.business_id = v_context.business_id
       and rv.config_version_id = sc.config_version_id
       and rv.active
       and rv.cost_points <= sc.slots
      join public.loyalty_rewards live
        on live.id = rv.reward_id
       and live.business_id = v_context.business_id
       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and app.reward_pause_on_offer_v814(live.paused, rv.paused, true)
       -- nestly_v568''s pot fence, stated here for the same reason it is stated in v432: the
       -- version join above says nothing about WHICH programme a reward belongs to, so without
       -- this a POINTS gift priced below the card''s length would be served as a stamp survivor.
       and live.programme_id = sc.programme_id
      cross join lateral (
        select app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id,
                 rv.min_tier_threshold) as threshold
      ) gate
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = v_context.business_id
           and lr.client_id = v_context.client_id
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        select (select x.expires_at
                  from app.stamp_reward_expiry_v464(v_context.business_id, v_context.client_id,
                         sc.programme_id, sc.cycle_index, rv.cost_points) x) as expires_at,
               exists (select 1 from public.stamp_reward_expiries_v464 e
                        where e.business_id = v_context.business_id
                          and e.client_id = v_context.client_id
                          and e.programme_id = sc.programme_id
                          and e.cycle_index = sc.cycle_index
                          and e.reward_id = rv.reward_id) as recorded
      ) expiry
     where sc.business_id = v_context.business_id
       and sc.client_id = v_context.client_id
       and sc.programme_id = v_progress.programme_id
       and sc.origin in (''expired'', ''claimed'', ''completed'')
       and not exists (
         select 1 from public.stamp_milestone_claims claim
          where claim.business_id = v_context.business_id
            and claim.client_id = v_context.client_id
            and claim.programme_id = sc.programme_id
            and claim.cycle_index = sc.cycle_index
            and claim.reward_id = rv.reward_id
       )
  ) carry;

  return jsonb_build_object(
    ''enabled'', true,';

  -- (B) the two new keys, and (C) a next_milestone that is actually reachable.
  v_return constant text :=
'    ''milestones'', v_milestones,
    ''next_milestone'', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> ''claimed_this_cycle'')::boolean is not true
       order by (rung.value ->> ''slot'')::integer
       limit 1)
  );';
  v_return_new constant text :=
'    ''milestones'', v_milestones,
    /* nestly_v845: gifts already won on a CLOSED cycle, waiting at the counter. Separate from
       `carried`, which counts carried-over STAMPS. */
    ''carried_rewards'', v_carried,
    ''carried_rewards_ready'', (
      select count(*)::integer from jsonb_array_elements(v_carried) as carry(value)
       where carry.value ->> ''availability'' = ''available_at_counter''),
    ''next_milestone'', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> ''claimed_this_cycle'')::boolean is not true
         /* nestly_v845: and the gift must still be REACHABLE. This filtered on
            claimed_this_cycle alone and ignored the availability computed a few lines above, so
            qa-kopi-lab''s next_milestone was a 4-stamp gift whose claim window had closed on
            2026-08-24 — "4 stamps to go" for something nobody can be given. The list is an
            allowlist rather than a list of dead states on purpose: a state added later is left
            OUT of next_milestone until somebody decides it belongs there, which is the safe
            direction for a line that tells a customer what to collect for. */
         and (rung.value ->> ''availability'') in
             (''insufficient_stamps'', ''available_at_counter'', ''not_started'',
              ''tier_locked'', ''paused'')
       order by (rung.value ->> ''slot'')::integer
       limit 1)
  );';
begin
  v_def := pg_get_functiondef('public.customer_get_stamp_card_v323(text)'::regprocedure);
  if position('nestly_v845' in v_def) > 0 then
    raise notice 'nestly_v845: customer_get_stamp_card_v323 already spliced, skipping';
    return;
  end if;

  v_new := replace(v_def,  v_declare, v_declare_new);
  v_new := replace(v_new,  v_case,    v_case_new);
  v_new := replace(v_new,  v_tail,    v_tail_new);
  v_new := replace(v_new,  v_return,  v_return_new);

  if v_new = v_def then
    raise exception 'nestly_v845: the splice changed nothing — refusing to claim a fix that '
                    'did not happen'
      using errcode = 'XX001';
  end if;
  execute v_new;
end
$v845_splice$;

-- ACLs, restated exactly as production holds them (postgres owner, service_role and
-- authenticated may execute; anon and public may not). CREATE OR REPLACE preserves them, so this
-- is a re-statement, never a widening.
revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

-- ============================================================================================
-- 3. VERIFY — the spliced reader is exercised against a tenant this block builds, inside a
--    SUB-TRANSACTION that is ALWAYS thrown away. Production must be byte-identical afterwards,
--    which the row-count checks at the end prove. An assertion failure raises P0001 (or any
--    other errcode), is NOT caught, and aborts the whole migration.
-- ============================================================================================
do $v845_verify$
declare
  v_biz uuid := gen_random_uuid();
  v_spine uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_ident uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid;
  v_g2 uuid := gen_random_uuid();
  v_g3 uuid := gen_random_uuid();
  v_g5 uuid := gen_random_uuid();
  v_seed uuid := gen_random_uuid();
  v_seed2 uuid;
  v_cfg uuid;
  v_slug text;
  v_json jsonb;
  v_txt text;
  v_n integer;
  v_fail text := '';
  -- Captured OUTSIDE the sub-transaction: the state the migration found.
  v_biz_before bigint;
  v_cycles_before bigint;
  v_users_before bigint;
  v_biz_after bigint;
  v_cycles_after bigint;
  v_users_after bigint;
begin
  select count(*) into v_biz_before from public.businesses;
  select count(*) into v_cycles_before from public.stamp_cycles;
  select count(*) into v_users_before from auth.users;

  begin
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
           decided_at = clock_timestamp(), decision_reason = 'v845 verify fixture',
           updated_at = clock_timestamp()
     where business_id = v_biz;
    insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
    values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;
    insert into public.subscriptions(business_id) values (v_biz) on conflict do nothing;
    insert into public.business_customer_capabilities_v89(business_id, redemption_enabled)
    values (v_biz, true) on conflict (business_id) do update set redemption_enabled = true;
    /* app.v32_customer_wallet_context refuses outright unless the platform wallet flag is on, so
       the fixture asserts it. This is a PLATFORM-WIDE row, which is precisely why the whole block
       lives inside the sub-transaction the P0845 sentinel throws away: production's own flag
       values are restored by that rollback, exactly as they were read. */
    insert into app.platform_feature_flags(feature_key, enabled)
    values ('customer_wallet', true), ('customer_claims', true), ('customer_qr_redemption', true)
    on conflict (feature_key) do update set enabled = true;

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
      raise exception 'v845 verify: FIXTURE BROKEN — the tenant published no configuration version';
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

    -- Three gifts on a five-slot card. The one at slot 2 has a claim window that CLOSED
    -- yesterday, so it is the lowest-slot milestone and it is dead: exactly defect (C).
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

    -- ---- positive control: 3 of 5 stamps, the slot-3 gift is claimable ---------------------
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_json := public.customer_get_stamp_card_v323(v_slug);
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
     where value ->> 'reward_id' = v_g3::text;
    if coalesce(v_txt, 'ABSENT') <> 'available_at_counter' then
      v_fail := v_fail || format('[control: slot-3 gift reads %s on a running card] ',
                                 coalesce(v_txt, 'ABSENT'));
    end if;

    -- ---- (C) next_milestone must skip the gift whose window closed --------------------------
    if coalesce(v_json -> 'next_milestone' ->> 'reward_id', 'NULL') = v_g2::text then
      v_fail := v_fail || '[C: next_milestone is still the ended slot-2 gift] ';
    end if;
    if coalesce(v_json -> 'next_milestone' ->> 'reward_id', 'NULL') <> v_g3::text then
      v_fail := v_fail || format('[C: next_milestone is %s, expected the open slot-3 gift] ',
                                 coalesce(v_json -> 'next_milestone' ->> 'reward_id', 'NULL'));
    end if;
    -- ...and the ended gift is still LISTED, marked 'ended'. Skipping it in next_milestone must
    -- not delete it from the card.
    select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
     where value ->> 'reward_id' = v_g2::text;
    if coalesce(v_txt, 'ABSENT') <> 'ended' then
      v_fail := v_fail || format('[C: the ended gift left the card or reads %s] ',
                                 coalesce(v_txt, 'ABSENT'));
    end if;

    -- ---- (A) stop the programme: a claimable gift becomes 'paused' --------------------------
    update public.business_programmes set active = false, deactivated_at = now()
     where id = v_spine;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_json := public.customer_get_stamp_card_v323(v_slug);
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    select value ->> 'availability' into v_txt from jsonb_array_elements(v_json -> 'milestones')
     where value ->> 'reward_id' = v_g3::text;
    if coalesce(v_txt, 'ABSENT') <> 'paused' then
      v_fail := v_fail || format('[A: a claimable gift on a STOPPED programme reads %s] ',
                                 coalesce(v_txt, 'ABSENT'));
    end if;
    -- and the counter agrees by offering nothing at all
    select count(*) into v_n
      from app.reward_availability_v432(v_biz, v_client) ra
     where ra.reward_id in (v_g2, v_g3, v_g5);
    if v_n <> 0 then
      v_fail := v_fail || format('[A: v432 unexpectedly offers %s stamp gift(s) on a stopped programme] ', v_n);
    end if;
    update public.business_programmes set active = true, deactivated_at = null where id = v_spine;

    -- ---- (B) fill the card, let it roll over, and read the survivors ------------------------
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
      v_fail := v_fail || format('[B: FIXTURE BROKEN — the full card did not close (%s cycles)] ', v_n);
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_cust, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_json := public.customer_get_stamp_card_v323(v_slug);
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

    if (v_json ->> 'filled')::integer <> 0 then
      v_fail := v_fail || format('[B: FIXTURE BROKEN — the fresh card is not empty (filled=%s)] ',
                                 v_json ->> 'filled');
    end if;
    if coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) <> 2 then
      v_fail := v_fail || format('[B: carried_rewards_ready=%s, expected 2 (the slot-3 and slot-5 gifts survived)] ',
                                 coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT'));
    end if;
    -- the number the card reports must be the number v432 offers, not a second opinion
    select coalesce(sum(ra.quantity), 0)::integer into v_n
      from app.reward_availability_v432(v_biz, v_client) ra
     where ra.availability = 'available_at_counter' and ra.unit = 'stamps';
    if coalesce((v_json ->> 'carried_rewards_ready')::integer, -1) <> v_n then
      v_fail := v_fail || format('[B: the card says %s ready, app.reward_availability_v432 says %s] ',
                                 coalesce(v_json ->> 'carried_rewards_ready', 'ABSENT'), v_n);
    end if;
    -- the dead gift survives too, but as 'ended' — never counted as ready
    select value ->> 'availability' into v_txt
      from jsonb_array_elements(v_json -> 'carried_rewards')
     where value ->> 'reward_id' = v_g2::text;
    if coalesce(v_txt, 'ABSENT') <> 'ended' then
      v_fail := v_fail || format('[B: the survivor of the closed-window gift reads %s] ',
                                 coalesce(v_txt, 'ABSENT'));
    end if;
    -- and the CURRENT card's grid is untouched: still three rungs, no survivor rows injected
    if jsonb_array_length(v_json -> 'milestones') <> 3 then
      v_fail := v_fail || format('[B: survivors leaked into the card grid (%s milestones)] ',
                                 jsonb_array_length(v_json -> 'milestones'));
    end if;

    if v_fail <> '' then
      raise exception 'nestly_v845 verify FAILED: %', v_fail;
    end if;

    raise exception 'v845 verify: rollback sentinel' using errcode = 'P0845';
  exception
    when sqlstate 'P0845' then
      null;  -- expected: every assertion passed, the whole fixture tenant is thrown away
  end;

  select count(*) into v_biz_after from public.businesses;
  select count(*) into v_cycles_after from public.stamp_cycles;
  select count(*) into v_users_after from auth.users;
  if v_biz_after <> v_biz_before then
    raise exception 'v845 verify: the verification block leaked businesses (% before, % after)',
      v_biz_before, v_biz_after;
  end if;
  if v_cycles_after <> v_cycles_before then
    raise exception 'v845 verify: the verification block leaked stamp_cycles rows (% before, % after)',
      v_cycles_before, v_cycles_after;
  end if;
  if v_users_after <> v_users_before then
    raise exception 'v845 verify: the verification block leaked auth.users rows (% before, % after)',
      v_users_before, v_users_after;
  end if;

  raise notice 'nestly_v845 verify ok: paused-before-ready, the survivor arm and a reachable '
               'next_milestone all proven in a rolled-back sub-transaction; production untouched';
end
$v845_verify$;

commit;
