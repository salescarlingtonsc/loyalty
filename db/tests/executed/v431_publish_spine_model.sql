-- v431 executed acceptance — publishing a draft cannot flip the declared model against the spine.
-- Dual-mode: BASELINE (pre-v431) pins the defect (publish restores the draft's stale model);
-- MIGRATED pins the fix (model follows the spine). RAISE on failure; everything rolls back.
begin;

do $$
declare
  v_has_v431 boolean := position('nestly_v431' in coalesce((
      select pg_get_functiondef(p.oid) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'publish_loyalty_config'), '')) > 0;
  v_biz uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_spine_stamps uuid := gen_random_uuid();
  v_draft uuid;
  v_reward uuid := gen_random_uuid();
  v_model text;
  v_kind text;
begin
  -- ========================================================================================
  -- SCRATCH TENANT (harness runs the real triggers: seeded spine rows, seeded config version,
  -- v94 workspace gates — same fixture recipe as v423's executed test)
  -- ========================================================================================
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v431-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V431 Scratch Cafe', 'v431-scratch-cafe', array['loyalty'], 'redeem');

  insert into public.staff(business_id, user_id, role, active)
  values (v_biz, v_owner, 'owner', true);
  insert into public.branches(business_id, name, is_default, active)
  values (v_biz, 'V431 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v431 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused=false;

  -- The c45 write guards on loyalty_program_versions fire on the FIXTURE's own inserts, so the
  -- owner identity is assumed before any guarded write, not just before the publish call.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- The engine that RUNS is stamps: claim the seeded spine row for stamps, points stays off.
  -- sort must match kind (business_programmes_sort_matches_kind): stamps = 3.
  insert into public.business_programmes(id, business_id, kind, active, sort)
  values (v_spine_stamps, v_biz, 'stamps', true, 3)
  on conflict (business_id, kind) do update set active = true
  returning id into v_spine_stamps;
  update public.business_programmes set active = false
   where business_id = v_biz and kind = 'points';

  -- The declared column starts DESYNCED — exactly the state the publish must not preserve.
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind, configuration_status,
                                      stamp_target, stamp_per_cents)
  values (v_biz, true, 'points_tiers', 'points', 'published', 5, 500)
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points',
        configuration_status='published', stamp_target=5, stamp_per_cents=500;

  -- A DRAFT cloned from that stale state: its loyalty_program_versions row says points_tiers,
  -- and it satisfies every stamps-spine publish validation (per-stamp spend, target, a gift AT
  -- the target on the stamps programme).
  select id into v_draft from public.firm_config_versions
   where business_id = v_biz and status = 'draft'
   order by version_no desc limit 1;
  if v_draft is null then
    v_draft := gen_random_uuid();
    insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
    select v_draft, v_biz, coalesce(max(version_no),0)+1, 'draft', md5('v431-draft')
      from public.firm_config_versions where business_id = v_biz;
  end if;
  insert into public.loyalty_program_versions(config_version_id, business_id, loyalty_model, kind,
    active, earn_points_per_dollar, redeem_points, reward_credit_cents, stamp_target, stamp_per_cents,
    tier_basis, expiry_mode, expiry_days)
  values (v_draft, v_biz, 'points_tiers', 'points', true, 1, 800, 500, 5, 500, 'visits', 'none', null)
  on conflict (config_version_id) do update
    set loyalty_model='points_tiers', kind='points', active=true, stamp_target=5, stamp_per_cents=500;

  insert into public.loyalty_rewards(id, business_id, name, internal_name, customer_name,
    fulfillment_kind, cost_points, credit_cents, estimated_cost_cents, active, paused, sort, programme_id)
  values (v_reward, v_biz, 'V431 Card Gift', 'V431 Card Gift', 'V431 Card Gift',
          'manual_item', 5, 0, 0, true, false, 1, v_spine_stamps);
  insert into public.loyalty_reward_versions(reward_id, business_id, config_version_id,
    internal_name, customer_name, fulfillment_kind, cost_points, credit_cents,
    estimated_cost_cents, active, sort, programme_id)
  values (v_reward, v_biz, v_draft, 'V431 Card Gift', 'V431 Card Gift', 'manual_item', 5, 0, 0, true, 1, v_spine_stamps);

  -- ========================================================================================
  -- 01  PUBLISH THE STALE DRAFT AS THE OWNER
  -- ========================================================================================
  execute 'set local role authenticated';
  perform public.publish_loyalty_config(v_draft);
  execute 'reset role';
  perform set_config('request.jwt.claims', '{}', true);

  select loyalty_model, kind into v_model, v_kind
    from public.loyalty_programs where business_id = v_biz;

  if v_has_v431 then
    if v_model is distinct from 'stamps' or v_kind is distinct from 'stamps' then
      raise exception '01 FAIL (migrated): publish let the stale draft flip the model off the spine — %/%', v_model, v_kind;
    end if;
    raise notice '01 ok (migrated): the published model follows the stamps spine';
  else
    if v_model = 'stamps' then
      raise exception '01 FAIL (baseline): expected the DEFECT (draft model restored), found spine model — the environment does not match production';
    end if;
    raise notice '01 ok (baseline): DEFECT REPRODUCED — publish restored %/% over an active stamps spine', v_model, v_kind;
  end if;
end $$;

rollback;
select 'v431 executed acceptance finished (see notices)' as result;
