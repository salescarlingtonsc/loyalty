-- Rollback-only acceptance for nestly_v507 — a business is LIVE from the moment it exists.
-- Run: supabase db query --linked -f db/tests/v507_a_business_is_born_live.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- The owner's ruling this pins (2026-08-25): "publish = live - not draft or configuration
-- follow" and "make sure on = live". Before v507, onboarding seeded the tenant's loyalty base as
-- a draft, app.seed_loyalty_config_version() copied that word into the v1 version row, and
-- businesses.active_config_version_id stayed NULL until the setup wizard's last step — so a
-- fully configured, switched-on programme earned nothing and served nothing. The engine's own
-- reader, app.resolve_loyalty_branch_config, returns NO ROW for a null active version.
--
--   01  BORN LIVE: inserting the standard onboarding preset (configuration_status='draft', the
--       exact values v95/v130/v277 insert) leaves the business with a PUBLISHED v1 adopted as
--       its active configuration — the trigger overrides the seeder's word.
--   02  the engine can read it: resolve_loyalty_branch_config returns one row at birth
--   03  ON = LIVE for gifts: with the points spine on, a gift saved through
--       business_create_reward_v326 reports publish_status='published' (the v505 draft fallback
--       is unreachable) and the customer is SERVED it immediately (insufficient_balance — they
--       hold 0 points — not invisible)
--   04  ON = LIVE for earning: one recorded sale writes a points_ledger earn row at the seeded
--       rate, with no publish step in between
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v507_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v507_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v507-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_spine uuid;
  v_client uuid := gen_random_uuid();
  v_active uuid;
  v_ver_status text;
  v_cfg_status text;
  v_gift uuid;
  v_sale uuid := gen_random_uuid();
  v_json jsonb;
  v_txt text; v_n integer;
begin
  -- ==========================================================================================
  -- FIXTURE — a brand-new tenant, seeded exactly as onboarding seeds one
  -- ==========================================================================================
  -- 'till' too: step 04 records a real sale, and the branch-module guard demands it.
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V507 Acceptance', v_slug, array['loyalty','till','sales'], 'redeem');
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz, 'points', true, 1)
  on conflict (business_id, kind) do update set active = true;
  select id into v_spine from public.business_programmes
   where business_id = v_biz and kind = 'points';

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v507-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V507 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_by = v_owner,
         decided_at = clock_timestamp(), decision_reason = 'v507 acceptance',
         updated_at = clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused = false;

  perform pg_temp.as_v507_user(v_owner);

  -- The onboarding preset, byte-identical to what v95/v130/v277 insert: note the seeder still
  -- says 'draft' and active=false. v507's whole point is that this word no longer decides
  -- anything.
  insert into public.loyalty_programs(business_id, kind, earn_points_per_dollar, redeem_points,
                                      reward_credit_cents, active, loyalty_model,
                                      configuration_status, recommendation_source)
  values (v_biz, 'points', 1, 800, 2000, false, 'classic', 'draft', 'onboarding_preset');

  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V507 Customer', '+65 9507 1001');

  -- ==========================================================================================
  -- 01  BORN LIVE
  -- ==========================================================================================
  select b.active_config_version_id into v_active from public.businesses b where b.id = v_biz;
  select v.status into v_ver_status from public.firm_config_versions v where v.id = v_active;
  select lp.configuration_status into v_cfg_status
    from public.loyalty_programs lp where lp.business_id = v_biz;
  insert into _r values('01_born_live',
    case when v_active is not null and v_ver_status = 'published' and v_cfg_status = 'published'
      then 'PASS the draft-seeded preset produced a published, adopted v1 — no wizard step needed'
      else 'FAIL active=' || coalesce(v_active::text,'null') || ' version=' || coalesce(v_ver_status,'null')
           || ' config=' || coalesce(v_cfg_status,'null') end);

  -- ==========================================================================================
  -- 02  THE ENGINE CAN READ IT
  -- ==========================================================================================
  select count(*) into v_n from app.resolve_loyalty_branch_config(v_biz, null, null);
  insert into _r values('02_engine_reads_config',
    case when v_n = 1 then 'PASS resolve_loyalty_branch_config returns the earn configuration at birth'
         else 'FAIL ' || v_n || ' config rows' end);

  -- ==========================================================================================
  -- 03  ON = LIVE FOR GIFTS
  -- ==========================================================================================
  v_json := public.business_create_reward_v326(v_biz, v_spine, 'V507 Gift', 10, 0, 'Redeem now');
  v_gift := (v_json ->> 'reward_id')::uuid;
  insert into _r values('03_gift_publishes_on_save',
    case when v_json ->> 'publish_status' = 'published'
          and coalesce((v_json ->> 'unpublished_draft')::boolean, false) = false
      then 'PASS Save = published — the v505 draft fallback is unreachable'
      else 'FAIL publish_status=' || coalesce(v_json ->> 'publish_status','null')
           || ' unpublished_draft=' || coalesce(v_json ->> 'unpublished_draft','null') end);
  select r.availability into v_txt
    from app.reward_availability_v432(v_biz, v_client, now()) r where r.reward_id = v_gift;
  insert into _r values('03_customer_served_immediately',
    case when v_txt = 'insufficient_balance'
      then 'PASS the customer sees the gift the moment it is saved (0 points, so not yet claimable)'
      else 'FAIL availability=' || coalesce(v_txt, 'INVISIBLE') end);

  -- ==========================================================================================
  -- 04  ON = LIVE FOR EARNING — one sale, points on the ledger, no publish step
  -- ==========================================================================================
  insert into public.sales(id, business_id, client_id, staff_id, branch_id, kind, amount_cents, note)
  select v_sale, v_biz, v_client, s.id, v_branch, 'quick_sale', 2500, 'v507 acceptance sale'
    from public.staff s where s.business_id = v_biz and s.user_id = v_owner;
  select coalesce(sum(pl.points), 0) into v_n
    from public.points_ledger pl
   where pl.business_id = v_biz and pl.client_id = v_client
     and pl.sale_id = v_sale and pl.entry_type = 'earn';
  insert into _r values('04_sale_earns_at_birth',
    case when v_n = 25
      then 'PASS S$25.00 at the seeded 1 pt/$ earned 25 points with no publish step'
      else 'FAIL earned ' || v_n || ' points (expected 25)' end);
end $$;

select * from _r order by k;
rollback;
