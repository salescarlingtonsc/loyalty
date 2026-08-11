-- Rollback-only acceptance for V277 — super-admin activation seeds the loyalty preset, and the
-- tenants activated without one were backfilled.
--
-- Runs against the REAL production schema inside ONE transaction and ends in ROLLBACK: nothing it
-- writes survives. Two of the four sections are read-only assertions about production state that
-- the migration COMMITTED (the backfill is a real change, not a rehearsal); the other two write
-- fixtures and undo them.
--
-- What this proves, in order:
--   1  Both super-admin activation paths — platform_decide_business_application_v105 (the V167
--      direct approval, which created Bistro 999) and platform_activate_approved_application_v169
--      — now carry the loyalty seed, its C45 owner-identity impersonation, and the caller-claim
--      snapshot; and the seed sits in the only window where it can work: AFTER the workspace
--      control is flipped to 'approved' (app.is_salon_owner calls app.business_workspace_open_v94,
--      so a seed placed any earlier is guaranteed to fail) and BEFORE the subscriptions insert.
--      v95's own long-standing seed is asserted untouched, so the migration did not disturb the
--      one path that already worked.
--   2  THE MECHANISM, on a synthetic tenant built and destroyed inside this transaction. Under the
--      SUPER ADMIN's claims the preset insert raises 42501 'owner loyalty configuration access
--      required' — this is the exact failure that made V169 delete the seed, reproduced. Under the
--      OWNER's claims the identical insert succeeds and materialises firm_config_versions v1 plus
--      its loyalty_program_versions row. That is the whole argument for the fix: the guard is not
--      weakened, it is satisfied by the identity it was written to require.
--   3  Nothing became customer-visible and nothing old moved. The seeded state is
--      active=false / configuration_status='draft' / firm_config_versions.status='draft' /
--      published_at NULL / businesses.active_config_version_id NULL. In production, every APPROVED
--      workspace now has exactly one loyalty_programs row; the one PAYMENT_PENDING self-service
--      signup (Cafe2U ded721a7) still has none, because it was never activated and
--      app.activate_self_serve_paid_v130 owns its seed; and a long-established tenant (Cubbly)
--      carries no V277 backfill audit row and still has its pre-V277 first config version.
--   4  The reported tenant is actually fixed: Bistro 999's REAL owner can now call
--      create_loyalty_config_draft and generate_retention_recommendation, both of which raised
--      before the migration ('base configuration not found' / 'loyalty draft is missing for this
--      business'). Its draft is created and then rolled back.

begin;

create or replace function pg_temp.as_v277_user(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v277_user(uuid) to public;

do $v277$
declare
  -- The tenant the owner reported, created 2026-08-11 by the V167 direct-approval path.
  v_bistro uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';
  -- Self-service signup still at payment_pending: correctly unseeded, must stay unseeded.
  v_unpaid uuid := 'ded721a7-6b3c-426f-8842-6ecf56725e01';
  -- Long-established tenant that must be provably untouched by the backfill.
  v_old uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  -- A super admin who is NOT staff of any tenant, so section 2 tests the real asymmetry.
  v_super uuid := '9229ef07-d12f-4dd4-bbaa-3ff287db7b30';

  v_v105 text;
  v_v169 text;
  v_v95 text;
  v_syn_user uuid := gen_random_uuid();
  v_syn_biz uuid;
  v_modules text[];
  v_owner uuid;
  v_state text;
  v_sqlstate text;
  v_program record;
  v_version record;
  v_count integer;
  v_draft uuid;
  v_json json;
begin
  -------------------------------------------------------------------------------------------
  -- 1. The deployed function objects.
  -------------------------------------------------------------------------------------------
  v_v105 := pg_get_functiondef(
    'public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)'::regprocedure);
  v_v169 := pg_get_functiondef(
    'public.platform_activate_approved_application_v169(uuid,uuid)'::regprocedure);
  v_v95 := pg_get_functiondef(
    'public.activate_approved_business_application_v95(text,text,uuid)'::regprocedure);

  if position('insert into public.loyalty_programs(' in v_v105) = 0 then
    raise exception 'v277.1: v105 does not seed loyalty_programs';
  end if;
  if position('insert into public.loyalty_programs(' in v_v169) = 0 then
    raise exception 'v277.1: v169 does not seed loyalty_programs';
  end if;
  if position('insert into public.loyalty_programs(' in v_v95) = 0 then
    raise exception 'v277.1: v95 lost its original seed';
  end if;

  if position('if app.c45_owner_loyalty_write(v_business.id) then' in v_v105) = 0
     or position('if app.c45_owner_loyalty_write(v_business.id) then' in v_v169) = 0 then
    raise exception 'v277.1: the C45 gate is missing from a super-admin activation path';
  end if;
  if position('v_v277_prior_claims text:=current_setting' in v_v105) = 0
     or position('v_v277_prior_claims text:=current_setting' in v_v169) = 0 then
    raise exception 'v277.1: the caller-claim snapshot is missing from a super-admin path';
  end if;
  -- The claims MUST be handed back, or every statement after the seed would run as the tenant
  -- owner inside a super-admin call.
  if position('perform set_config(''request.jwt.claims'',coalesce(v_v277_prior_claims,''''),true);'
              in v_v105) = 0
     or position('perform set_config(''request.jwt.claims'',coalesce(v_v277_prior_claims,''''),true);'
              in v_v169) = 0 then
    raise exception 'v277.1: a super-admin path does not restore the caller claims after seeding';
  end if;

  -- Window: workspace approval < seed < subscriptions.
  if not (position('''application_activated''' in v_v105)
          < position('insert into public.loyalty_programs(' in v_v105)
          and position('insert into public.loyalty_programs(' in v_v105)
          < position('insert into public.subscriptions(business_id)' in v_v105)) then
    raise exception 'v277.1: the v105 seed is outside the approved-workspace window';
  end if;
  if not (position('''application_activated''' in v_v169)
          < position('insert into public.loyalty_programs(' in v_v169)
          and position('insert into public.loyalty_programs(' in v_v169)
          < position('insert into public.subscriptions(business_id)' in v_v169)) then
    raise exception 'v277.1: the v169 seed is outside the approved-workspace window';
  end if;

  -- The preset must be the v95 preset, or a platform-activated tenant would start life in a
  -- different state from an owner-activated one.
  if position('''points'',1,800,2000,false,''classic'',''draft''' in v_v105) = 0
     or position('''points'',1,800,2000,false,''classic'',''draft''' in v_v169) = 0
     or position('''points'',1,800,2000,false,''classic'',''draft''' in v_v95) = 0 then
    raise exception 'v277.1: the seeded preset diverges from the v95 preset';
  end if;

  -------------------------------------------------------------------------------------------
  -- 2. The mechanism, on a synthetic tenant.
  -------------------------------------------------------------------------------------------
  -- SCAFFOLDING: enabled_modules cannot be invented. business_modules_dependency_guard runs
  -- resolve_module_dependencies() over the array and raises 22023 'unknown modules: ...' for any
  -- key that is not a real module, so the fixture borrows a REAL published bundle instead of
  -- hand-writing a plausible-looking list.
  select modules into v_modules
    from public.sector_bundle_versions
   where sector_key = 'fnb' and status = 'published';
  if v_modules is null or not ('loyalty' = any(v_modules)) then
    raise exception 'v277.2: no published fnb bundle carrying loyalty to borrow';
  end if;

  insert into auth.users(id) values (v_syn_user);
  insert into public.businesses(name, slug, industry, enabled_modules)
  values ('ZZ-V277 mechanism fixture', 'zz-v277-' || replace(v_syn_user::text, '-', ''),
          'fnb', v_modules)
  returning id into v_syn_biz;
  -- v94 seeds every direct business insert as pending; open it exactly as an activation would,
  -- because app.is_salon_owner -> app.business_workspace_open_v94 depends on it.
  -- SCAFFOLDING: business_workspace_controls_v94_decision_shape is a CHECK constraint, not a
  -- convention: any non-pending status REQUIRES decided_at plus a decision_reason of 3..1000
  -- trimmed characters. Flipping approval_status alone raises 23514.
  update public.business_workspace_controls_v94
     set approval_status = 'approved', version = version + 1, decided_at = now(),
         decision_reason = 'v277 acceptance fixture', updated_at = now()
   where business_id = v_syn_biz;
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_syn_biz, v_syn_user, 'owner', 'V277 fixture owner', true);

  -- 2a. Under the SUPER ADMIN. This is the V169 failure, reproduced.
  perform pg_temp.as_v277_user(v_super);
  begin
    insert into public.loyalty_programs(
      business_id, kind, earn_points_per_dollar, redeem_points,
      reward_credit_cents, active, loyalty_model, configuration_status, recommendation_source
    ) values (v_syn_biz, 'points', 1, 800, 2000, false, 'classic', 'draft', 'onboarding_preset');
    raise exception 'v277.2a: the super admin was allowed to seed tenant loyalty configuration';
  exception
    when sqlstate '42501' then
      null; -- expected: C45 refused the super admin
  end;
  select count(*) into v_count from public.loyalty_programs where business_id = v_syn_biz;
  if v_count <> 0 then
    raise exception 'v277.2a: a refused seed still left % row(s)', v_count;
  end if;

  -- 2b. Under the OWNER. Identical statement, different identity.
  perform pg_temp.as_v277_user(v_syn_user);
  if not app.c45_owner_loyalty_write(v_syn_biz) then
    raise exception 'v277.2b: the C45 gate is false for the tenant owner - the seed would be skipped';
  end if;
  insert into public.loyalty_programs(
    business_id, kind, earn_points_per_dollar, redeem_points,
    reward_credit_cents, active, loyalty_model, configuration_status, recommendation_source
  ) values (v_syn_biz, 'points', 1, 800, 2000, false, 'classic', 'draft', 'onboarding_preset');
  perform pg_temp.as_v277_user(null);

  select * into v_program from public.loyalty_programs where business_id = v_syn_biz;
  if v_program.current_config_version_id is null then
    raise exception 'v277.2b: the seed did not back-link a config version';
  end if;
  if v_program.active is not false or v_program.configuration_status <> 'draft' then
    raise exception 'v277.2b: the seed is not an inactive draft (active=%, status=%)',
      v_program.active, v_program.configuration_status;
  end if;
  select * into v_version from public.firm_config_versions
   where id = v_program.current_config_version_id;
  if v_version.version_no <> 1 or v_version.status <> 'draft'
     or v_version.published_at is not null then
    raise exception 'v277.2b: config v1 is not an unpublished draft (no=%, status=%, published=%)',
      v_version.version_no, v_version.status, v_version.published_at;
  end if;
  select count(*) into v_count from public.loyalty_program_versions
   where config_version_id = v_program.current_config_version_id;
  if v_count <> 1 then
    raise exception 'v277.2b: expected 1 programme version row, found %', v_count;
  end if;
  if (select active_config_version_id from public.businesses where id = v_syn_biz) is not null then
    raise exception 'v277.2b: the seed published a customer-visible configuration';
  end if;

  -------------------------------------------------------------------------------------------
  -- 3. Production state after the committed backfill.
  -------------------------------------------------------------------------------------------
  select count(*) into v_count
    from public.businesses business
    join public.business_workspace_controls_v94 control on control.business_id = business.id
   where control.approval_status = 'approved'
     and business.id <> v_syn_biz
     and not exists (select 1 from public.loyalty_programs program
                      where program.business_id = business.id);
  if v_count <> 0 then
    raise exception 'v277.3: % approved workspace(s) still have no loyalty base', v_count;
  end if;

  select count(*) into v_count from public.loyalty_programs where business_id = v_unpaid;
  if v_count <> 0 then
    raise exception 'v277.3: the payment_pending self-service tenant was seeded (% row(s))', v_count;
  end if;
  select control.approval_status into v_state
    from public.business_workspace_controls_v94 control where control.business_id = v_unpaid;
  if v_state <> 'pending' then
    raise exception 'v277.3: the unpaid fixture is no longer pending (%) - reselect it', v_state;
  end if;

  select count(*) into v_count from public.audit_log
   where business_id = v_old and action = 'ACTIVATION_LOYALTY_SEED_BACKFILL_V277';
  if v_count <> 0 then
    raise exception 'v277.3: an established tenant was touched by the backfill';
  end if;
  select count(*) into v_count from public.firm_config_versions
   where business_id = v_old and version_no = 1 and created_at < timestamptz '2026-08-11';
  if v_count <> 1 then
    raise exception 'v277.3: the established tenant lost or gained a v1 config version';
  end if;

  -------------------------------------------------------------------------------------------
  -- 4. The reported tenant can now open Grow.
  -------------------------------------------------------------------------------------------
  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_bistro and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   limit 1;
  if v_owner is null then
    raise exception 'v277.4: the reported tenant has no approved active owner';
  end if;

  perform pg_temp.as_v277_user(v_owner);
  -- SCAFFOLDING: create_loyalty_config_draft returns JSON
  -- {version_id, version_no, status}, not a bare uuid. Assigning it straight to a uuid variable
  -- fails with 22P02 on the whole JSON object.
  v_json := public.create_loyalty_config_draft(v_bistro, null, 'v277-acceptance');
  perform pg_temp.as_v277_user(null);
  v_draft := (v_json->>'version_id')::uuid;
  if v_draft is null then
    raise exception 'v277.4: create_loyalty_config_draft returned no version_id';
  end if;
  select status into v_state from public.firm_config_versions where id = v_draft;
  if v_state <> 'draft' then
    raise exception 'v277.4: the new configuration is % rather than a draft', v_state;
  end if;
  -- Detach rather than delete: every child of firm_config_versions is ON DELETE RESTRICT, and
  -- the recommender below only needs the base to have no draft hanging off it.
  update public.firm_config_versions set based_on_version_id = null where id = v_draft;

  perform pg_temp.as_v277_user(v_owner);
  v_json := public.generate_retention_recommendation(
    v_bistro, 'v277-acceptance-' || gen_random_uuid()::text);
  perform pg_temp.as_v277_user(null);
  if (v_json->>'model') is null then
    raise exception 'v277.4: the recommender returned no model for the reported tenant';
  end if;
  -- Bistro 999 is a bar, so V276 must be reflected here too: the two migrations compose.
  if (v_json->>'model') <> 'points_tiers' then
    raise exception 'v277.4: the bar tenant was recommended % instead of points_tiers',
      v_json->>'model';
  end if;

  raise notice 'v277: all assertions passed (every fixture write is undone by ROLLBACK)';
end
$v277$;

rollback;
