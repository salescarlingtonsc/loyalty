-- EXECUTED EVIDENCE — nestly_v426 canonical tier resolver.
--
-- This file is db/tests/v426_tier_resolver.sql exactly as it was run, with the run recorded
-- above it. It is discovered automatically by scripts/db-tests/run.mjs (`npm run test:db`),
-- which executes it TWICE: once against the committed schema baseline and once with the pending
-- migrations applied. It passes in both, which is the point — see the header of the test itself.
--
-- HOW IT WAS RUN
--   DB_TESTS_PORT=54487 DB_TESTS_WORKDIR=<scratch> node scripts/db-tests/run.mjs --filter=v426
--   (a non-default port because another session's harness already held 54499; nothing about the
--    run depends on the port)
--
-- WHAT THE HARNESS BUILT
--   422 tables, 1365 routines from tests/fixtures/db-schema-snapshot.sql (watermark v422) —
--   the real schema, real triggers, real guards, real RLS objects. Then, in version order:
--     applied  v423  20260822_nestly_v423_reward_edit_reaches_customers.sql
--     applied  v424  20260822_nestly_v424_birthday_window_honoured.sql
--     applied  v425  20260822_nestly_v425_referral_explicit_reward_type.sql
--     applied  v426  20260822_nestly_v426_canonical_tier_resolver.sql
--     applied  v427  20260822_nestly_v427_entitlements_reach_customers.sql
--   v426 applied clean, alongside its four wave siblings, with no notices and no errors.
--   sha256 of the migration (both copies are byte-identical):
--     956555315c770fc545106e92bee702a3ec982b37d36cb451f9c02f9b8e2d99b6
--
-- RESULT
--   ── BASELINE (against peekaa_baseline) ──
--     ok    v426_tier_resolver.sql  (728ms)
--     NOTICE:  v426 canonical tier resolver [BASELINE]: 42 assertions passed
--   ── MIGRATED (against peekaa_migrated) ──
--     ok    v426_tier_resolver.sql  (664ms)
--     NOTICE:  v426 canonical tier resolver [MIGRATED]: 57 assertions passed
--   all executed SQL passed in 5.3s
--
--   The 42 baseline assertions are not a weaker version of the 57: they pin the DEFECT — the
--   display reader answering Bronze with a null basis and a zero metric while the earn engine
--   applies Silver, the switched-off ladder still granting Gold at the till, the stamps business
--   told "points", the conversion arriving as two anonymous adjustments. If a later change
--   quietly fixed any of those without this migration, the baseline half would fail and say so.
--
-- RETURN-SHAPE COMPATIBILITY, measured separately.
--   A second harness (bare PostgreSQL 17.10, LC_ALL=C, port 54426) was loaded with production's
--   own function bodies — pulled with pg_get_functiondef via `supabase db query --linked`, read
--   only — and two committed fixture businesses:
--     same/*   an ACTIVE programme, one pot, tiers running: nothing may change.
--     fixed/*  the live Hougang ABC + Cubbly SPA shape (inactive programme row, two pots).
--   Eleven payloads were captured before the migration and again after, and byte-compared as
--   jsonb:
--     fixed/loyalty_tier_for | IDENTICAL   Silver -> Silver   (the engine was already canonical)
--     fixed/v176             | CHANGED     0 -> 150
--     fixed/v365_client_tier | CHANGED     Bronze -> Silver
--     fixed/v393             | CHANGED     Bronze / basis null / metric 0
--                                          -> Silver / points_earned / 150
--     same/c45               | IDENTICAL
--     same/loyalty_tier_for  | IDENTICAL
--     same/v143              | IDENTICAL   the entire payload: ladder, benefits, progress,
--                                          points_mode, tier_fuel, balance_scope
--     same/v167              | CHANGED     gains exactly one key (below)
--     same/v176              | IDENTICAL
--     same/v365_client_tier  | IDENTICAL
--     same/v393              | IDENTICAL
--   Every changed payload moved TO the earn engine's answer. Nothing moved away from it.
--
--   v167 item keys before: branch_name, description, event_at, event_type, gross_cents,
--   is_package_session, line_items, net_cents, points_earned, points_redeemed, points_removed,
--   related_source_id, sale_kind, source_id, source_kind, status.
--   After: the same sixteen, plus `entry`. Nothing removed, nothing renamed. A row that IS a
--   conversion additionally carries entry_group, entry_role, points_delta, stamps_delta,
--   converted_points, issued_stamps, points_per_stamp, leftover_points, converted_customers and
--   conversion_batch_key.
--
-- NEGATIVE CONTROLS, on that same second harness — the test re-run with production's pre-image
-- bodies restored, to prove it is not vacuous. Each failed, in its own section:
--   all seven pre-images restored:
--     ERROR:  v426 A: shown metric/basis 0/<NULL> <> canonical 50/points_earned
--   only app.c45_base_actionable_wallet_card restored:
--     ERROR:  v426 D: stamps wallet card said unit=points model=points_tiers
--   only public.customer_get_transaction_history_v167 restored:
--     ERROR:  v426 F: the conversion was not tagged — two "Points adjustment" rows, one
--             reporting points_removed 75800 and one points_earned 758, and nothing else
--   v426 reapplied after each: 57 assertions passed.
--
-- NOT COVERED BY EITHER RUN, stated so nobody assumes otherwise: row level security (both
-- harnesses run as a superuser; every function under test is SECURITY DEFINER owned by
-- postgres), and production DATA. The behaviour is proven against production's schema and
-- production's function bodies, not against its rows.
--
-- ROLLBACK. Replay the production bodies captured on 2026-08-22 for app.loyalty_tier_for,
-- app.v365_client_tier, app.customer_tier_json_v393, app.v176_tier_gate_metric,
-- public.customer_get_effective_tier_v143, app.c45_base_actionable_wallet_card and
-- public.customer_get_transaction_history_v167, then drop app.tier_resolve_v426 and
-- app.conversion_tag_v426. The data half does not roll back from inside the migration; the
-- pre-image of every production row it touches is:
--   Cubbly SPA   8492e8d6-8888-4383-ada0-7e1ed69f0caa  loyalty_model 'points_tiers', kind 'points'
--   Hougang ABC  53677cf5-abb8-4a41-a17b-17cdc0bc06d4  loyalty_model 'classic',      kind 'points'
--   No other row in public.loyalty_programs differs from the spine (verified 2026-08-22).
--
-- ============================================================================================
-- The test, verbatim.
-- ============================================================================================

-- Rollback-only acceptance for nestly_v426: one canonical tier resolution path.
--
-- BIDIRECTIONAL, because scripts/db-tests/run.mjs runs every db/tests/executed/*.sql twice —
-- once against the baseline schema and once with the pending migrations applied — and a file
-- that only passes in the second run is a test written to the new code rather than to the
-- behaviour. So this file pins BOTH worlds from one fixture: before v426 it asserts the defect
-- exactly as it was reported on production, after v426 it asserts the fix. The sections that
-- were never supposed to change (B and E) assert the same thing in both phases, unconditionally,
-- and that is what makes the pass meaningful rather than tautological.
--
-- What the fixture is built to catch, section by section:
--   A. POINTS BASIS. The business carries an INACTIVE loyalty_programs row with tier_basis =
--      'points_earned' (the live Hougang ABC shape) and TWO points pots, only one of them the
--      running programme (the live Cubbly SPA shape). Every client's visit count is zero and the
--      dead pot is deliberately huge, so a reader that fell back to the visits basis answers the
--      bottom rung for everyone, and a reader that summed every pot answers the top rung for
--      everyone. Below / exactly at / above each threshold, the displayed tier, the applied tier
--      and the gate metric must be one number.
--   B. VISITS BASIS, active programme, through the whole customer path including
--      public.customer_get_effective_tier_v143 with a real verified customer link. Identical
--      before and after — this is the regression half.
--   C. The Tiers spine switch. Configured tiers with the programme switched OFF granted a
--      multiplier at earn time and a tier at checkout; after v426 they grant nothing, while the
--      gate metric — which answers "how far has this customer come", not "which rung" — still
--      reports the real number.
--   D. The Home wallet card's model and unit. The fixture deliberately desyncs
--      loyalty_programs.loyalty_model from the spine, so a card still reading that column is
--      caught in either direction.
--   E. The v354 sync backfill statement, replayed: it writes exactly the desynced rows, and a
--      second run writes nothing. Identical before and after.
--   F. A points-to-stamps conversion in the customer's history: two anonymous "Points
--      adjustment" lines before, one tagged collapsible event after.
--
-- Run as postgres. Writes nothing that survives.

begin;

/* public.points_ledger is append-only through named routes only. Earn fixtures use a zero-value
   gift-card sale, whose immutable policy is revenue=false / visit=false / earn=false, solely as
   the required sale provenance for the sale_trigger route. It therefore cannot perturb the
   visit metrics this file proves. Adjust fixtures use programme_pot_transfer. */
create or replace function pg_temp.v426_ledger(
  p_business uuid, p_client uuid, p_entry text, p_points integer, p_programme uuid,
  p_reference text, p_at timestamptz default null
) returns uuid language plpgsql as $fn$
declare
  v_id uuid := gen_random_uuid();
  v_scope text := case when p_entry='earn' then 'sale_trigger' else 'programme_pot_transfer' end;
  v_sale uuid;
begin
  if to_regprocedure('app.acquire_loyalty_shared_v480(uuid)') is not null then
    execute 'select app.acquire_loyalty_shared_v480($1)' using p_business;
  end if;
  if p_entry='earn' then
    insert into public.sales(id,business_id,client_id,kind,amount_cents)
    values(gen_random_uuid(),p_business,p_client,'gift_card',0)
    returning id into v_sale;
  end if;
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', v_scope, true);
  insert into public.points_ledger(
    id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id,
    created_at
  ) values (
    v_id, p_business, p_client, p_entry, p_points, v_sale, p_reference, null, p_programme,
    coalesce(p_at, now())
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  return v_id;
end
$fn$;
grant execute on function pg_temp.v426_ledger(uuid,uuid,text,integer,uuid,text,timestamptz)
  to public;

/* public.customer_links is guarded the same way (app.v31_link_immutable_guard): a link may only
   be created by a route that names the row it is about to write. */
create or replace function pg_temp.v426_link(
  p_business uuid, p_identity uuid, p_auth uuid, p_client uuid
) returns uuid language plpgsql as $fn$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.customer_link_insert_id', v_id::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at
  ) values (
    v_id, p_business, p_identity, p_auth, p_client, 'verified', 'qr_join', now()
  );
  perform set_config('app.customer_link_insert_id', '', true);
  return v_id;
end
$fn$;
grant execute on function pg_temp.v426_link(uuid,uuid,uuid,uuid) to public;

do $v426$
declare
  -- Which world are we in? The resolver's existence is the switch; nothing else in the file
  -- guesses at a version number.
  v_v426 boolean := to_regprocedure('app.tier_resolve_v426(uuid,uuid,timestamp with time zone)')
                    is not null;

  -- A: points basis, inactive programme row, two pots
  v_biz_p uuid := gen_random_uuid();
  v_pot_points uuid := gen_random_uuid();
  v_pot_stamps uuid := gen_random_uuid();
  v_p_below uuid := gen_random_uuid();
  v_p_exact uuid := gen_random_uuid();
  v_p_above uuid := gen_random_uuid();
  -- B: visits basis, real customer session
  v_biz_v uuid := gen_random_uuid();
  v_v_pot uuid := gen_random_uuid();
  v_v_below uuid := gen_random_uuid();
  v_v_exact uuid := gen_random_uuid();
  v_v_above uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_auth uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  -- C: tiers switched off
  v_biz_off uuid := gen_random_uuid();
  v_off_pot uuid := gen_random_uuid();
  v_off_client uuid := gen_random_uuid();
  -- D: wallet card
  v_biz_stamps uuid := gen_random_uuid();
  v_biz_points uuid := gen_random_uuid();
  v_stamps_pot uuid := gen_random_uuid();
  v_points_pot uuid := gen_random_uuid();
  v_points_tiers uuid := gen_random_uuid();
  v_stamps_client uuid := gen_random_uuid();
  v_points_client uuid := gen_random_uuid();
  v_cfg_stamps uuid := gen_random_uuid();
  v_cfg_points uuid := gen_random_uuid();
  v_reward_stamps uuid := gen_random_uuid();
  v_reward_points uuid := gen_random_uuid();
  -- F: conversion
  v_conv_at timestamptz := now() - interval '1 hour';
  -- scratch
  v_resolved jsonb; v_tier public.loyalty_tiers%rowtype; v_json jsonb; v_card jsonb;
  v_history jsonb; v_item jsonb; v_metric numeric; v_rows integer; v_n integer; v_slug text;
  v_assertions integer := 0;
begin
  ---------------------------------------------------------------------------------------------
  -- FIXTURE A — points basis, INACTIVE loyalty_programs row, two pots, tiers running.
  ---------------------------------------------------------------------------------------------
  insert into public.businesses(id,name,slug,currency,industry,enabled_modules,points_mode)
  values (v_biz_p,'V426 Points Fixture','v426-points-'||left(v_biz_p::text,8),'SGD','fnb',
          array['loyalty']::text[],'redeem');

  -- active = false is the whole point: the earn engine reads tier_basis without that filter,
  -- every display-side reader used to read it WITH the filter, get no row at all, and fall
  -- through to the visits branch.
  insert into public.loyalty_programs(business_id,kind,active,tier_basis,loyalty_model,
    earn_points_per_dollar,redeem_points,expiry_mode,configuration_status)
  values (v_biz_p,'points',false,'points_earned','classic',1,800,'none','published');

  -- app.seed_business_programmes_v314 already created the four spine rows when the business row
  -- landed, so the fixture SETS the owner's switches rather than inserting rows that exist.
  update public.business_programmes set active = (kind in ('points','tiers'))
   where business_id = v_biz_p;
  select id into v_pot_points from public.business_programmes
   where business_id = v_biz_p and kind = 'points';
  select id into v_pot_stamps from public.business_programmes
   where business_id = v_biz_p and kind = 'stamps';

  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,perk_note,sort)
  values (v_biz_p,'Bronze',0,1,'Welcome',1),
         (v_biz_p,'Silver',100,1.25,'A little more'||E'\n'||'Free drink',2),
         (v_biz_p,'Gold',200,1.5,'The most',3);

  insert into public.clients(id,business_id,full_name) values
    (v_p_below,v_biz_p,'V426 Below'),
    (v_p_exact,v_biz_p,'V426 Exact'),
    (v_p_above,v_biz_p,'V426 Above');

  -- Live pot: 50 / 100 / 250 -> Bronze / Silver / Gold.
  -- Dead pot: 5000 each, so any unscoped reader answers Gold for all three.
  -- No sales at all, so any reader that falls back to visits answers Bronze for all three.
  perform pg_temp.v426_ledger(v_biz_p,v_p_below,'earn',50,v_pot_points,'v426 fixture');
  perform pg_temp.v426_ledger(v_biz_p,v_p_exact,'earn',100,v_pot_points,'v426 fixture');
  perform pg_temp.v426_ledger(v_biz_p,v_p_above,'earn',250,v_pot_points,'v426 fixture');
  perform pg_temp.v426_ledger(v_biz_p,v_p_below,'earn',5000,v_pot_stamps,'v426 dead pot');
  perform pg_temp.v426_ledger(v_biz_p,v_p_exact,'earn',5000,v_pot_stamps,'v426 dead pot');
  perform pg_temp.v426_ledger(v_biz_p,v_p_above,'earn',5000,v_pot_stamps,'v426 dead pot');

  ---------------------------------------------------------------------------------------------
  -- A — below / exactly at / above threshold, on the points basis.
  ---------------------------------------------------------------------------------------------
  foreach v_item in array array[
    jsonb_build_object('client',v_p_below,'tier','Bronze','metric',50),
    jsonb_build_object('client',v_p_exact,'tier','Silver','metric',100),
    jsonb_build_object('client',v_p_above,'tier','Gold','metric',250)
  ] loop
    -- APPLIED: the row app.on_sale_recorded multiplies by. Canonical in both worlds — it is the
    -- reading the others are being moved onto, so it must not move.
    select * into v_tier from app.loyalty_tier_for(v_biz_p,(v_item->>'client')::uuid);
    if v_tier.name is distinct from v_item->>'tier' then
      raise exception 'v426 A: applied tier % <> expected %', v_tier.name, v_item->>'tier';
    end if;
    v_assertions := v_assertions + 1;

    v_json := app.customer_tier_json_v393(v_biz_p,(v_item->>'client')::uuid);
    v_metric := app.v176_tier_gate_metric(v_biz_p,(v_item->>'client')::uuid);

    if v_v426 then
      v_resolved := app.tier_resolve_v426(v_biz_p,(v_item->>'client')::uuid);
      if v_resolved->>'basis' <> 'points_earned' then
        raise exception 'v426 A: canonical basis fell back to %', v_resolved->>'basis';
      end if;
      if (v_resolved->>'metric')::numeric <> (v_item->>'metric')::numeric then
        raise exception 'v426 A: metric % is not the live pot total % (unscoped would be %)',
          v_resolved->>'metric', v_item->>'metric', (v_item->>'metric')::integer + 5000;
      end if;
      -- DISPLAYED == APPLIED == GATE. This is the owner-locked invariant, in one place.
      if v_json->>'name' is distinct from v_tier.name then
        raise exception 'v426 A: shown tier % <> applied tier %', v_json->>'name', v_tier.name;
      end if;
      if (v_json->>'metric')::numeric <> (v_resolved->>'metric')::numeric
         or v_json->>'basis' <> 'points_earned' then
        raise exception 'v426 A: shown metric/basis %/% <> canonical %/%',
          v_json->>'metric', v_json->>'basis', v_resolved->>'metric', v_resolved->>'basis';
      end if;
      if v_metric <> (v_resolved->>'metric')::numeric then
        raise exception 'v426 A: gate metric % <> canonical metric %', v_metric,
          v_resolved->>'metric';
      end if;
      select * into v_tier from app.v365_client_tier(v_biz_p,(v_item->>'client')::uuid);
      if v_tier.name is distinct from v_item->>'tier' then
        raise exception 'v426 A: checkout tier % <> expected %', v_tier.name, v_item->>'tier';
      end if;
      v_assertions := v_assertions + 5;
    else
      -- BASELINE: pin the defect. The display reader finds no active programme row, so its
      -- basis is NULL, it counts visits (zero), and it names the bottom rung for everybody
      -- while the engine above just named three different ones.
      if v_json->>'basis' is not null or (v_json->>'metric')::numeric <> 0
         or v_json->>'name' <> 'Bronze' then
        raise exception 'v426 A baseline: expected the reported defect, got basis=% metric=% name=%',
          v_json->>'basis', v_json->>'metric', v_json->>'name';
      end if;
      if v_metric <> 0 then
        raise exception 'v426 A baseline: expected the gate metric to read 0, got %', v_metric;
      end if;
      v_assertions := v_assertions + 2;
    end if;
  end loop;

  ---------------------------------------------------------------------------------------------
  -- FIXTURE B — visits basis, active programme, a real verified customer session.
  ---------------------------------------------------------------------------------------------
  insert into public.businesses(id,name,slug,currency,industry,enabled_modules,points_mode)
  values (v_biz_v,'V426 Visits Fixture','v426-visits-'||left(v_biz_v::text,8),'SGD','fnb',
          array['loyalty','sales','till']::text[],'redeem');
  select slug into v_slug from public.businesses where id = v_biz_v;
  insert into public.branches(id,business_id,name,active,is_default)
  values (v_branch,v_biz_v,'Main',true,true);
  -- app.seed_business_workspace_control_v94 / _lifecycle_v94 already created these rows when the
  -- business landed; approving one requires a decision timestamp and a reason (the v94 shape
  -- check), so this is an update, not an insert.
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decision_reason='v426 acceptance fixture'
   where business_id = v_biz_v;
  update public.business_subscription_lifecycle_v94
     set workspace_paused = false where business_id = v_biz_v;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved+unpaused workspace above.
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz_v, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  insert into app.platform_feature_flags(feature_key,enabled) values ('customer_wallet',true)
    on conflict (feature_key) do update set enabled = true;

  insert into public.loyalty_programs(business_id,kind,active,tier_basis,loyalty_model,
    earn_points_per_dollar,redeem_points,expiry_mode,configuration_status)
  values (v_biz_v,'points',true,'visits','classic',1,800,'none','published');
  update public.business_programmes set active = (kind in ('points','tiers'))
   where business_id = v_biz_v;
  select id into v_v_pot from public.business_programmes
   where business_id = v_biz_v and kind = 'points';
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,perk_note,sort)
  values (v_biz_v,'Bronze',0,1,'Welcome',1),
         (v_biz_v,'Silver',2,1.25,'Halfway',2),
         (v_biz_v,'Gold',4,1.5,'Top',3);

  insert into public.clients(id,business_id,full_name) values
    (v_v_below,v_biz_v,'V426 One Visit'),
    (v_v_exact,v_biz_v,'V426 Two Visits'),
    (v_v_above,v_biz_v,'V426 Five Visits');

  insert into public.sales(business_id,client_id,branch_id,kind,amount_cents,counts_as_revenue,
    counts_as_visit,earns_points,policy_resolved_at,commission_rate_bps,commission_resolved_at,
    occurred_at)
  select v_biz_v, seed.client_id, v_branch, 'quick_sale', 1000, true, true, false, now(), 0, now(),
         now() - (seed.n || ' days')::interval
    from (
      select v_v_below as client_id, generate_series(1,1) as n
      union all select v_v_exact, generate_series(1,2)
      union all select v_v_above, generate_series(1,5)
    ) seed;

  -- Fixture sanity: these rows pass through the real sale-policy triggers. If they came out
  -- classified differently the rest of B is meaningless, so fail here rather than assert
  -- against a number nobody chose.
  select count(*) into v_n from public.sales
   where business_id = v_biz_v and client_id = v_v_exact and counts_as_visit;
  if v_n <> 2 then
    raise exception 'v426 B fixture: expected 2 qualifying visits, sale policy produced %', v_n;
  end if;
  v_assertions := v_assertions + 1;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_auth,'authenticated','authenticated',
          'v426-'||left(v_auth::text,8)||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values (v_identity,v_auth,'active','wallet_start');
  -- The same person is a verified customer at BOTH fixture businesses, so the guard assertion
  -- below fails at the programme check rather than at the link check.
  perform pg_temp.v426_link(v_biz_v,v_identity,v_auth,v_v_exact);
  perform pg_temp.v426_link(v_biz_p,v_identity,v_auth,v_p_exact);
  -- app.seed_business_workspace_control_v94 / _lifecycle_v94 already created these rows when the
  -- business landed; approving one requires a decision timestamp and a reason (the v94 shape
  -- check), so this is an update, not an insert.
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decision_reason='v426 acceptance fixture'
   where business_id = v_biz_p;
  update public.business_subscription_lifecycle_v94
     set workspace_paused = false where business_id = v_biz_p;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved+unpaused workspace above.
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz_p, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  -- A16 — the module guard on the customer screen is unchanged, in both phases. With the
  -- workspace approved and the module enabled, the ONLY remaining reason to refuse is the
  -- inactive programme row: v426 did not quietly start answering where v143 used to refuse.
  begin
    perform set_config('request.jwt.claim.sub', v_auth::text, true);
    perform public.customer_get_effective_tier_v143(v_biz_p);
    raise exception 'v426 A: customer_get_effective_tier_v143 answered for an inactive programme';
  exception when sqlstate '42501' then
    if sqlerrm not like '%loyalty module is unavailable%' then
      raise exception 'v426 A: v143 refused for the wrong reason: %', sqlerrm;
    end if;
    v_assertions := v_assertions + 1;
  end;
  perform set_config('request.jwt.claim.sub', '', true);

  ---------------------------------------------------------------------------------------------
  -- B — the same three positions on the visits basis. UNCONDITIONAL: identical in both phases.
  ---------------------------------------------------------------------------------------------
  foreach v_item in array array[
    jsonb_build_object('client',v_v_below,'tier','Bronze','metric',1),
    jsonb_build_object('client',v_v_exact,'tier','Silver','metric',2),
    jsonb_build_object('client',v_v_above,'tier','Gold','metric',5)
  ] loop
    select * into v_tier from app.loyalty_tier_for(v_biz_v,(v_item->>'client')::uuid);
    if v_tier.name is distinct from v_item->>'tier' then
      raise exception 'v426 B: applied tier % <> %', v_tier.name, v_item->>'tier';
    end if;
    v_json := app.customer_tier_json_v393(v_biz_v,(v_item->>'client')::uuid);
    v_metric := app.v176_tier_gate_metric(v_biz_v,(v_item->>'client')::uuid);
    if v_json->>'name' is distinct from v_tier.name
       or v_json->>'basis' <> 'visits'
       or (v_json->>'metric')::numeric <> (v_item->>'metric')::numeric
       or v_metric <> (v_item->>'metric')::numeric then
      raise exception 'v426 B: shown %/%/% and gate % disagree with applied %',
        v_json->>'name', v_json->>'basis', v_json->>'metric', v_metric, v_tier.name;
    end if;
    select * into v_tier from app.v365_client_tier(v_biz_v,(v_item->>'client')::uuid);
    if v_tier.name is distinct from v_item->>'tier' then
      raise exception 'v426 B: checkout tier % <> %', v_tier.name, v_item->>'tier';
    end if;
    v_assertions := v_assertions + 3;
  end loop;

  -- B — the customer's own screen, through auth, on the exact-threshold client. Also
  -- unconditional: v143 was already reading the canonical basis and the canonical pot, so its
  -- whole payload must survive the rewrite untouched.
  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  v_json := public.customer_get_effective_tier_v143(v_biz_v);
  perform set_config('request.jwt.claim.sub', '', true);

  if v_json#>>'{tier,basis}' <> 'visits' then
    raise exception 'v426 B: customer screen basis %', v_json#>>'{tier,basis}';
  end if;
  if (v_json#>>'{tier,metric}')::numeric <> 2 then
    raise exception 'v426 B: customer screen metric %', v_json#>>'{tier,metric}';
  end if;
  if v_json#>>'{tier,current,label}' <> 'Silver' or v_json#>>'{tier,label}' <> 'Silver' then
    raise exception 'v426 B: customer screen tier %', v_json#>>'{tier,current,label}';
  end if;
  if v_json#>>'{tier,next,label}' <> 'Gold' then
    raise exception 'v426 B: customer screen next tier %', v_json#>>'{tier,next,label}';
  end if;
  if (v_json#>>'{tier,progress_percent}')::numeric <> 0 then
    raise exception 'v426 B: progress % (2 visits, Silver at 2, Gold at 4 -> 0%%)',
      v_json#>>'{tier,progress_percent}';
  end if;
  -- the ladder still carries all three rungs, still marks the achieved ones and the current one,
  -- and still splits perk_note into one benefit per line
  if jsonb_array_length(v_json#>'{tier,tiers}') <> 3
     or (v_json#>>'{tier,tiers,1,current}')::boolean is distinct from true
     or (v_json#>>'{tier,tiers,0,achieved}')::boolean is distinct from true
     or (v_json#>>'{tier,tiers,2,achieved}')::boolean is distinct from false
     or v_json#>>'{tier,tiers,1,label}' <> 'Silver'
     or v_json#>>'{tier,tiers,1,benefits,0}' <> 'Halfway' then
    raise exception 'v426 B: ladder shape changed: %', v_json#>'{tier,tiers}';
  end if;
  if v_json#>>'{tier,tier_fuel}' <> 'points_programme_earn'
     or v_json#>>'{tier,balance_scope}' is null then
    raise exception 'v426 B: customer screen lost a key: %', v_json;
  end if;
  v_assertions := v_assertions + 7;

  ---------------------------------------------------------------------------------------------
  -- FIXTURE C — the Tiers programme switched OFF.
  ---------------------------------------------------------------------------------------------
  insert into public.businesses(id,name,slug,currency,industry,enabled_modules,points_mode)
  values (v_biz_off,'V426 Tiers Off','v426-off-'||left(v_biz_off::text,8),'SGD','fnb',
          array['loyalty']::text[],'redeem');
  insert into public.loyalty_programs(business_id,kind,active,tier_basis,loyalty_model,
    configuration_status)
  values (v_biz_off,'points',true,'points_earned','points_tiers','published');
  update public.business_programmes set active = (kind = 'points') where business_id = v_biz_off;
  select id into v_off_pot from public.business_programmes
   where business_id = v_biz_off and kind = 'points';
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort)
  values (v_biz_off,'Bronze',0,1,1),(v_biz_off,'Gold',10,2,2);
  insert into public.clients(id,business_id,full_name) values (v_off_client,v_biz_off,'V426 Off');
  perform pg_temp.v426_ledger(v_biz_off,v_off_client,'earn',500,v_off_pot,'v426 fixture');

  -- The metric is not a tier. A reward gated on "how far have you come" must still be
  -- answerable when the ladder is off, and that is true in both phases.
  if app.v176_tier_gate_metric(v_biz_off,v_off_client) <> 500 then
    raise exception 'v426 C: gate metric lost when the ladder was switched off';
  end if;
  v_assertions := v_assertions + 1;

  select * into v_tier from app.loyalty_tier_for(v_biz_off,v_off_client);
  if v_v426 then
    v_resolved := app.tier_resolve_v426(v_biz_off,v_off_client);
    if (v_resolved->>'tiers_running')::boolean is distinct from false
       or jsonb_typeof(v_resolved->'current') <> 'null'
       or jsonb_typeof(v_resolved->'next') <> 'null'
       or jsonb_array_length(v_resolved->'ladder') <> 0 then
      raise exception 'v426 C: a switched-off ladder still resolved: %', v_resolved;
    end if;
    if v_tier.id is not null then
      raise exception 'v426 C: earn engine still applied % with tiers switched off', v_tier.name;
    end if;
    select * into v_tier from app.v365_client_tier(v_biz_off,v_off_client);
    if v_tier.id is not null then
      raise exception 'v426 C: checkout still applied % with tiers switched off', v_tier.name;
    end if;
    if app.customer_tier_json_v393(v_biz_off,v_off_client) is not null then
      raise exception 'v426 C: customer snapshot still showed a tier with tiers switched off';
    end if;
    v_assertions := v_assertions + 4;
  else
    -- BASELINE: pin the leak. Only public.customer_get_effective_tier_v143 honoured the switch;
    -- the earn engine and the checkout reader handed out the top rung regardless.
    if v_tier.name is distinct from 'Gold' then
      raise exception 'v426 C baseline: expected the switched-off ladder to still apply Gold, got %',
        v_tier.name;
    end if;
    select * into v_tier from app.v365_client_tier(v_biz_off,v_off_client);
    if v_tier.name is distinct from 'Gold' then
      raise exception 'v426 C baseline: expected checkout to still apply Gold, got %', v_tier.name;
    end if;
    v_assertions := v_assertions + 2;
  end if;

  ---------------------------------------------------------------------------------------------
  -- FIXTURE D — the Home wallet card's model and unit.
  ---------------------------------------------------------------------------------------------
  insert into public.businesses(id,name,slug,currency,industry,enabled_modules,points_mode)
  values (v_biz_stamps,'V426 Stamps','v426-stamps-'||left(v_biz_stamps::text,8),'SGD','fnb',
          array['loyalty']::text[],'redeem'),
         (v_biz_points,'V426 Points Wallet','v426-pw-'||left(v_biz_points::text,8),'SGD','fnb',
          array['loyalty']::text[],'redeem');
  insert into public.loyalty_programs(business_id,kind,active,tier_basis,loyalty_model,
    stamp_target,stamp_per_cents,configuration_status)
  values (v_biz_stamps,'stamps',true,'visits','stamps',5,500,'published');
  insert into public.loyalty_programs(business_id,kind,active,tier_basis,loyalty_model,
    earn_points_per_dollar,configuration_status)
  values (v_biz_points,'points',true,'visits','classic',1,'published');

  -- app.seed_loyalty_config_version published a version for each of these when the programme row
  -- landed, and pointed businesses.active_config_version_id at it. The reward catalogue the
  -- wallet card reads is keyed on THAT version, so the fixture takes the one the product made
  -- rather than inventing a second.
  select active_config_version_id into v_cfg_stamps from public.businesses where id = v_biz_stamps;
  select active_config_version_id into v_cfg_points from public.businesses where id = v_biz_points;
  if v_cfg_stamps is null or v_cfg_points is null then
    raise exception 'v426 D fixture: no published config version was seeded';
  end if;

  -- Both businesses carry a spine row for EVERY programme kind, which is what
  -- public.set_programmes_v314 writes and what all ten live tenants have. It matters: when a
  -- spine row is genuinely absent, app.programme_running_v371 falls back to
  -- app.business_programmes_v307, which derives the answer from loyalty_programs.loyalty_model —
  -- the very column this migration stops trusting. A fixture without the inactive rows would
  -- resurrect the stale column through the back door and prove nothing.
  update public.business_programmes set active = (kind = 'stamps') where business_id = v_biz_stamps;
  update public.business_programmes set active = (kind in ('points','tiers'))
   where business_id = v_biz_points;
  select id into v_stamps_pot from public.business_programmes
   where business_id = v_biz_stamps and kind = 'stamps';
  select id into v_points_pot from public.business_programmes
   where business_id = v_biz_points and kind = 'points';
  select id into v_points_tiers from public.business_programmes
   where business_id = v_biz_points and kind = 'tiers';
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort)
  values (v_biz_points,'Bronze',0,1,1);

  insert into public.clients(id,business_id,full_name) values
    (v_stamps_client,v_biz_stamps,'V426 Stamp Holder'),
    (v_points_client,v_biz_points,'V426 Point Holder');
  perform pg_temp.v426_ledger(v_biz_stamps,v_stamps_client,'earn',3,v_stamps_pot,'v426 fixture');
  perform pg_temp.v426_ledger(v_biz_points,v_points_client,'earn',40,v_points_pot,'v426 fixture');
  insert into public.points_batches(business_id,client_id,earned,remaining,programme_id,earned_at)
  values (v_biz_stamps,v_stamps_client,3,3,v_stamps_pot,now()),
         (v_biz_points,v_points_client,40,40,v_points_pot,now());

  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,cost_points,
    credit_cents,estimated_cost_cents,fulfillment_kind,programme_id,active,sort,paused,
    current_config_version_id)
  values (v_reward_stamps,v_biz_stamps,'Free wash','Free wash','Free wash',5,0,0,'manual_item',
          v_stamps_pot,true,1,false,v_cfg_stamps),
         (v_reward_points,v_biz_points,'Free coffee','Free coffee','Free coffee',100,0,0,'manual_item',
          v_points_pot,true,1,false,v_cfg_points);
  insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,internal_name,
    customer_name,fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,sort,
    programme_id)
  values (v_reward_stamps,v_biz_stamps,v_cfg_stamps,'Free wash','Free wash','manual_item',5,0,0,true,1,
          v_stamps_pot),
         (v_reward_points,v_biz_points,v_cfg_points,'Free coffee','Free coffee','manual_item',100,0,0,
          true,1,v_points_pot);

  -- Desync the column from the spine, in both directions, on purpose. A card reading the column
  -- answers backwards; a card reading the spine is unmoved.
  update public.loyalty_programs set loyalty_model = 'points_tiers', kind = 'points'
   where business_id = v_biz_stamps;
  update public.loyalty_programs set loyalty_model = 'stamps', kind = 'stamps'
   where business_id = v_biz_points;

  v_card := app.c45_base_actionable_wallet_card(v_biz_stamps,v_stamps_client,'v426-stamps',
    'V426 Stamps','fnb','SGD',array['loyalty']::text[],now());
  -- The balance is already spine-scoped (app.live_balance_programme_v381, v381/v384) in both
  -- phases; it is only the NOUN over it that was wrong.
  if (v_card#>>'{loyalty,balance}')::integer <> 3 then
    raise exception 'v426 D: stamps balance % <> 3', v_card#>>'{loyalty,balance}';
  end if;
  -- and every neighbouring key is present in both phases
  if v_card#>>'{action,reason}' is null or v_card#>>'{action,sort_band}' is null
     or v_card#>>'{credit,balance_cents}' is null or v_card#>>'{expiry,mode}' is null
     or v_card#>>'{business,slug}' <> 'v426-stamps'
     or (v_card#>>'{next_eligible_reward,remaining_units}')::integer <> 2 then
    raise exception 'v426 D: wallet card lost a key: %', v_card;
  end if;
  v_assertions := v_assertions + 2;

  if v_v426 then
    if v_card#>>'{loyalty,unit}' <> 'stamps' or v_card#>>'{loyalty,model}' <> 'stamps' then
      raise exception 'v426 D: stamps wallet card said unit=% model=%',
        v_card#>>'{loyalty,unit}', v_card#>>'{loyalty,model}';
    end if;
    if v_card#>>'{next_eligible_reward,unit}' <> 'stamps' then
      raise exception 'v426 D: next reward unit %', v_card#>>'{next_eligible_reward,unit}';
    end if;
    v_card := app.c45_base_actionable_wallet_card(v_biz_points,v_points_client,'v426-pw',
      'V426 Points Wallet','fnb','SGD',array['loyalty']::text[],now());
    if v_card#>>'{loyalty,unit}' <> 'points' or v_card#>>'{loyalty,model}' <> 'points_tiers' then
      raise exception 'v426 D: points wallet card said unit=% model=%',
        v_card#>>'{loyalty,unit}', v_card#>>'{loyalty,model}';
    end if;
    if v_card#>>'{next_eligible_reward,unit}' <> 'points' then
      raise exception 'v426 D: points reward unit %', v_card#>>'{next_eligible_reward,unit}';
    end if;
    v_assertions := v_assertions + 4;
  else
    -- BASELINE: pin the defect — the card takes the customer's noun from the stale column, so a
    -- stamps business is told "points" over a stamp balance, which is what the owner reported.
    if v_card#>>'{loyalty,unit}' <> 'points' or v_card#>>'{loyalty,model}' <> 'points_tiers' then
      raise exception 'v426 D baseline: expected the stale column to win, got unit=% model=%',
        v_card#>>'{loyalty,unit}', v_card#>>'{loyalty,model}';
    end if;
    if v_card #> '{next_eligible_reward}' ? 'unit' then
      raise exception 'v426 D baseline: next_eligible_reward already carried a unit key';
    end if;
    v_card := app.c45_base_actionable_wallet_card(v_biz_points,v_points_client,'v426-pw',
      'V426 Points Wallet','fnb','SGD',array['loyalty']::text[],now());
    if v_card#>>'{loyalty,unit}' <> 'stamps' then
      raise exception 'v426 D baseline: expected the stale column to win, got unit=%',
        v_card#>>'{loyalty,unit}';
    end if;
    v_assertions := v_assertions + 3;
  end if;

  ---------------------------------------------------------------------------------------------
  -- E — the v354 sync backfill statement, replayed. UNCONDITIONAL: the statement is inline, so
  --     it behaves the same in both phases; what it proves is that the migration's DML writes
  --     the desynced rows, only those, and nothing at all on a second run.
  ---------------------------------------------------------------------------------------------
  with spine as (
    select programme.business_id,
      bool_or(programme.kind = 'stamps' and programme.active) as stamps_on,
      bool_or(programme.kind = 'points' and programme.active) as points_on,
      bool_or(programme.kind = 'tiers'  and programme.active) as tiers_on
    from public.business_programmes programme
    where programme.business_id in (v_biz_stamps, v_biz_points)
    group by programme.business_id
  ), intended as (
    select spine.business_id,
      case when spine.stamps_on then 'stamps'
           when spine.points_on and spine.tiers_on then 'points_tiers'
           when spine.points_on then 'classic' end as loyalty_model,
      case when spine.stamps_on then 'stamps' when spine.points_on then 'points' end as kind
    from spine where spine.stamps_on or spine.points_on
  )
  update public.loyalty_programs program
     set loyalty_model = intended.loyalty_model, kind = intended.kind
    from intended
   where intended.business_id = program.business_id
     and (program.loyalty_model is distinct from intended.loyalty_model
       or program.kind is distinct from intended.kind);
  get diagnostics v_rows = row_count;
  if v_rows <> 2 then
    raise exception 'v426 E: backfill wrote % rows, expected 2', v_rows;
  end if;
  select count(*) into v_n from public.loyalty_programs
   where (business_id = v_biz_stamps and loyalty_model = 'stamps' and kind = 'stamps')
      or (business_id = v_biz_points and loyalty_model = 'points_tiers' and kind = 'points');
  if v_n <> 2 then
    raise exception 'v426 E: backfill left % of 2 rows in sync with the spine', v_n;
  end if;

  with spine as (
    select programme.business_id,
      bool_or(programme.kind = 'stamps' and programme.active) as stamps_on,
      bool_or(programme.kind = 'points' and programme.active) as points_on,
      bool_or(programme.kind = 'tiers'  and programme.active) as tiers_on
    from public.business_programmes programme
    where programme.business_id in (v_biz_stamps, v_biz_points)
    group by programme.business_id
  ), intended as (
    select spine.business_id,
      case when spine.stamps_on then 'stamps'
           when spine.points_on and spine.tiers_on then 'points_tiers'
           when spine.points_on then 'classic' end as loyalty_model,
      case when spine.stamps_on then 'stamps' when spine.points_on then 'points' end as kind
    from spine where spine.stamps_on or spine.points_on
  )
  update public.loyalty_programs program
     set loyalty_model = intended.loyalty_model, kind = intended.kind
    from intended
   where intended.business_id = program.business_id
     and (program.loyalty_model is distinct from intended.loyalty_model
       or program.kind is distinct from intended.kind);
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'v426 E: backfill is not idempotent, second run wrote % rows', v_rows;
  end if;
  v_assertions := v_assertions + 3;

  ---------------------------------------------------------------------------------------------
  -- F — a conversion in the customer's history.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v426_ledger(v_biz_v,v_v_exact,'adjust',-75800,v_v_pot,
    'stamp conversion: points spent',v_conv_at);
  perform pg_temp.v426_ledger(v_biz_v,v_v_exact,'adjust',758,v_v_pot,
    'stamp conversion: stamps issued',v_conv_at);
  insert into public.programme_stamp_conversions_v384(business_id,idempotency_key,
    points_programme_id,stamps_programme_id,points_per_stamp,converted_customers,converted_points,
    issued_stamps,leftover_points,response,created_at)
  values (v_biz_v,gen_random_uuid(),v_v_pot,v_v_pot,100,1,75800,758,0,'{}'::jsonb,v_conv_at);

  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  v_history := public.customer_get_transaction_history_v167(v_slug, '{}'::jsonb);
  perform set_config('request.jwt.claim.sub', '', true);

  -- Both phases: the raw rows are there, and the package tagging that already lived here still is.
  select count(*) into v_n
    from jsonb_array_elements(v_history->'items') as listed(item)
   where item->>'source_kind' = 'points_ledger' and item->>'event_type' = 'points_adjust';
  if v_n <> 2 then
    raise exception 'v426 F: % raw conversion rows in the history, expected 2', v_n;
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_history->'items') as listed(item)
     where not (item ? 'is_package_session')
  ) then
    raise exception 'v426 F: the v167 package tag was lost';
  end if;
  v_assertions := v_assertions + 2;

  if v_v426 then
    select item into v_item
      from jsonb_array_elements(v_history->'items') as listed(item)
     where item->>'entry' = 'conversion' and item->>'entry_role' = 'stamps_issued'
     limit 1;
    if v_item is null then
      raise exception 'v426 F: the conversion was not tagged: %', v_history->'items';
    end if;
    if (v_item->>'points_delta')::integer <> -75800
       or (v_item->>'stamps_delta')::integer <> 758
       or (v_item->>'converted_points')::integer <> 75800
       or (v_item->>'issued_stamps')::integer <> 758
       or (v_item->>'points_per_stamp')::integer <> 100 then
      raise exception 'v426 F: conversion tag carries the wrong numbers: %', v_item;
    end if;
    -- both halves share one group key, which is how the client collapses them into one line
    select count(distinct item->>'entry_group') into v_n
      from jsonb_array_elements(v_history->'items') as listed(item)
     where item->>'entry' = 'conversion';
    if v_n <> 1 then
      raise exception 'v426 F: the conversion pair carries % group keys, expected 1', v_n;
    end if;
    -- every other item still answers the key, with null
    if exists (
      select 1 from jsonb_array_elements(v_history->'items') as listed(item)
       where not (item ? 'entry')
    ) then
      raise exception 'v426 F: some history items have no entry key at all';
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_history->'items') as listed(item)
       where item->>'source_kind' = 'sale' and item->>'entry' is not null
    ) then
      raise exception 'v426 F: a plain sale was tagged as a conversion';
    end if;
    v_assertions := v_assertions + 5;
  else
    -- BASELINE: pin the defect — the conversion reaches the customer as two anonymous
    -- "Points adjustment" lines with nothing to tell them apart or join them together.
    if exists (
      select 1 from jsonb_array_elements(v_history->'items') as listed(item) where item ? 'entry'
    ) then
      raise exception 'v426 F baseline: history items already carried an entry key';
    end if;
    select count(*) into v_n
      from jsonb_array_elements(v_history->'items') as listed(item)
     where item->>'description' = 'Points adjustment';
    if v_n <> 2 then
      raise exception 'v426 F baseline: expected 2 anonymous adjustments, got %', v_n;
    end if;
    v_assertions := v_assertions + 2;
  end if;

  raise notice 'v426 canonical tier resolver [%]: % assertions passed',
    case when v_v426 then 'MIGRATED' else 'BASELINE' end, v_assertions;
end
$v426$;

rollback;
