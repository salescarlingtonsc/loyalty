-- NESTLY v277 — SUPER-ADMIN ACTIVATION MUST SEED THE LOYALTY PRESET (and backfill the tenants
-- that were activated without one)
--
-- THE SYMPTOM. Owner, 2026-08-11, on the brand-new bar tenant "Bistro 999"
-- (a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a): the Grow / loyalty surface cannot be started at all.
-- Probed against production as that tenant's real owner, both entry points raise:
--     create_loyalty_config_draft(business, null, ...)  -> P0001 'base configuration not found'
--     generate_retention_recommendation(business, ...)  -> P0001 'loyalty draft is missing for
--                                                                 this business'
-- Neither is recoverable from the UI, because BOTH are the "create my first programme" call.
-- The tenant has 0 loyalty_programs, 0 firm_config_versions and 0 loyalty_program_versions rows.
--
-- THE CAUSE, AND WHY IT IS NOT AN OVERSIGHT. A workspace's whole loyalty tree hangs off ONE row:
-- public.loyalty_programs. Inserting it fires AFTER INSERT app.seed_loyalty_config_version(),
-- which mints firm_config_versions v1 plus its loyalty_program_versions row and back-links
-- current_config_version_id. Every later draft is created "based on" that v1. With no seed row
-- there is no base, so the two RPCs above are correct to refuse — there is genuinely nothing to
-- branch from.
--
-- Of the four functions that create a business, only ONE performs that seed today:
--   public.activate_approved_business_application_v95    SEEDS  (owner activates their own
--                                                               workspace; auth.uid() = owner)
--   app.activate_self_serve_paid_v130 (trigger)          SEEDS  (impersonates the locked owner)
--   public.platform_decide_business_application_v105     DOES NOT   <- V167 direct approval
--   public.platform_activate_approved_application_v169   DOES NOT   <- V169 stranded activation
--
-- In v105 the omission is explicit and commented. V169 REMOVED the seed from it, because the
-- seed's version row trips app.c45_loyalty_program_version_write_guard on
-- firm_config_versions.status='draft'; that guard demands app.c45_owner_loyalty_write(business),
-- i.e. app.is_salon_owner(business), i.e. an active approved owner staff row whose user_id =
-- auth.uid(). During a super-admin approval auth.uid() is the SUPER ADMIN, who by design is never
-- tenant staff — so the guard raised 42501 and rolled back the ENTIRE approval. Removing the seed
-- was the right emergency call: it unblocked approvals. The reasoning recorded alongside it was
-- not: the comment claims the owner "create[s] their programme through Grow as the owner, where
-- the guard legitimately passes". They cannot. Grow's create path needs a base configuration that
-- only this seed produces. So every tenant activated by a super admin since 2026-08-04 has been
-- shipped with a permanently unopenable loyalty module.
--
-- THE FIX, COPIED FROM THE PATH THAT ALREADY SOLVED THIS. app.activate_self_serve_paid_v130 has
-- exactly the same problem — a provider webhook, not the owner, triggers activation — and solves
-- it without weakening anything: it temporarily publishes the LOCKED OWNER's claims into the
-- transaction-local GUCs, performs one idempotent preset insert, then restores the caller's
-- claims. C45 sees the owner it was written to require; no grant, no RLS policy and no C45
-- predicate changes; the super admin gains no new write path into tenant loyalty configuration,
-- because the identity used is the owner the same function just created a staff row for.
-- V277 splices that exact shape into v105 and v169. The preset values and recommendation_source
-- are byte-identical to v95's ('points',1,800,2000,active=false,'classic','draft',
-- 'onboarding_preset'), so a super-admin-activated tenant is now indistinguishable from an
-- owner-activated one.
--
-- THE SEED IS GATED, SO IT CAN NEVER AGAIN BREAK AN ACTIVATION. The insert runs only
-- `if app.c45_owner_loyalty_write(v_business.id)` — the guard's own predicate, evaluated under
-- the owner claims. If a sector bundle ever ships without 'loyalty' in enabled_modules, or the
-- workspace control is not yet open, the seed is skipped and the approval still completes. That
-- is the failure mode V169 was protecting, kept, but now costing a skipped preset instead of a
-- lost workspace. In every current sector bundle the predicate is true.
--
-- HOW THE FUNCTIONS ARE EDITED, AND WHY. Both are large settled SECURITY DEFINER functions
-- (v105 is ~10KB and owns the whole approve/reject decision). Retyping either to add twelve lines
-- would be the riskiest possible way to add twelve lines. So the migration reads each function's
-- OWN deployed source with pg_get_functiondef, splices two fragments, and re-executes it. Every
-- needle is pure SQL with no comment text in it — the MCP migration path strips comments, and a
-- comment-anchored needle would silently miss (see the rehearsal-vs-prod note in team memory).
-- Each splice asserts EXACTLY ONE occurrence before running, and the result is verified against
-- the DEPLOYED definition afterwards, so each function is either changed precisely as intended or
-- not at all. Re-running is safe: a function that already carries the seed is skipped.
--
-- The stale V169 comment block inside v105 is rewritten in passing so the next reader does not
-- delete the seed again on its authority. That rewrite is best-effort (0-or-1 occurrences) and
-- never gates the change.
--
-- THE BACKFILL. Fixing the functions does nothing for tenants already activated. Section 3
-- inserts the same seed, under the same owner impersonation, for every business that has BOTH
-- zero firm_config_versions AND zero loyalty_programs rows. Three deliberate restrictions:
--   * only workspaces whose business_workspace_controls_v94.approval_status='approved'. The
--     fifth zero-config tenant, "Cafe2U" ded721a7-6b3c-426f-8842-6ecf56725e01, is a self-service
--     signup still at status='payment_pending' with a PENDING workspace. It has no seed because
--     it has not been activated, which is correct, not broken; app.activate_self_serve_paid_v130
--     will seed it the moment payment is confirmed. Seeding it here would make an unpaid,
--     locked workspace look configured.
--   * the seed lands as active=false / configuration_status='draft' / firm_config_versions v1
--     with status='draft' and published_at NULL, and businesses.active_config_version_id is left
--     NULL. NOTHING becomes customer-visible. It is the same standing start a v95 tenant gets.
--   * a tenant that has EVER had a config is untouched: the zero-AND-zero predicate excludes any
--     business with even one historical firm_config_versions row, so a tenant that deliberately
--     deleted its programme cannot be silently re-seeded.
-- The backfill is idempotent (on conflict do nothing, plus the not-exists predicate) and asserts
-- afterwards that every row it selected is now seeded — if any tenant could not be seeded the
-- whole migration aborts rather than reporting a false success.
--
-- Rollback-only acceptance for the function change: db/tests/v277_activation_seeds_loyalty.sql.
-- The backfill is a real committed change and is evidenced by per-tenant before/after counts.

begin;

-- =================================================================================================
-- 1. Splice the owner-identity loyalty seed into the two super-admin activation functions.
-- =================================================================================================
do $v277$
declare
  v_target text;
  v_source text;
  v_patched text;
  v_hits integer;
  v_patched_count integer := 0;
  v_targets constant text[] := array[
    'public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)',
    'public.platform_activate_approved_application_v169(uuid,uuid)'
  ];

  -- Anchor 1: the DECLARE header. Both functions open with exactly this line, and the two new
  -- variables must be initialised at block entry so they capture the CALLER's claims before
  -- anything in the body can move them.
  v_declare_needle constant text := E'declare\n  v_actor uuid:=auth.uid();\n';
  v_declare_patch constant text := E'declare\n  v_actor uuid:=auth.uid();\n'
    || E'  v_v277_prior_sub text:=current_setting(''request.jwt.claim.sub'',true);\n'
    || E'  v_v277_prior_claims text:=current_setting(''request.jwt.claims'',true);\n';

  -- Anchor 2: the subscriptions insert. In BOTH functions this sits immediately after the
  -- workspace control has been flipped to 'approved' — which matters, because
  -- app.is_salon_owner() calls app.business_workspace_open_v94() and would be false any earlier.
  v_seed_needle constant text :=
    E'  insert into public.subscriptions(business_id) values(v_business.id)\n'
    || E'  on conflict(business_id) do nothing;';
  v_seed_patch constant text :=
    E'  perform set_config(''request.jwt.claim.sub'',v_owner::text,true);\n'
    || E'  perform set_config(''request.jwt.claims'',\n'
    || E'    jsonb_build_object(''sub'',v_owner,''role'',''authenticated'',''aud'',''authenticated'')::text,true);\n'
    || E'  if app.c45_owner_loyalty_write(v_business.id) then\n'
    || E'    insert into public.loyalty_programs(\n'
    || E'      business_id,kind,earn_points_per_dollar,redeem_points,\n'
    || E'      reward_credit_cents,active,loyalty_model,configuration_status,\n'
    || E'      recommendation_source\n'
    || E'    ) values(\n'
    || E'      v_business.id,''points'',1,800,2000,false,''classic'',''draft'',\n'
    || E'      ''onboarding_preset''\n'
    || E'    ) on conflict(business_id) do nothing;\n'
    || E'  end if;\n'
    || E'  perform set_config(''request.jwt.claim.sub'',coalesce(v_v277_prior_sub,''''),true);\n'
    || E'  perform set_config(''request.jwt.claims'',coalesce(v_v277_prior_claims,''''),true);\n'
    || E'  insert into public.subscriptions(business_id) values(v_business.id)\n'
    || E'  on conflict(business_id) do nothing;';

  -- Best-effort: retire the V169 note that told the next reader the omission was harmless.
  v_stale_note constant text :=
    'V169: the loyalty_programs seed that used to sit here is removed.';
  v_fresh_note constant text :=
    'V169 removed the loyalty_programs seed from here and V277 restored it, just below, under '
    || 'the owner identity (the app.activate_self_serve_paid_v130 shape). Do not remove it again: '
    || 'without it public.create_loyalty_config_draft raises base configuration not found and the '
    || 'tenant can never open Grow. The V169 note that followed is kept for history and its '
    || 'closing claim - that the owner could just build the programme in Grow - was wrong.';
begin
  foreach v_target in array v_targets loop
    v_source := pg_get_functiondef(v_target::regprocedure);

    -- Idempotency. The removed-seed COMMENT in v105 mentions loyalty_programs but never this
    -- exact INSERT, so this needle matches the real seed and nothing else.
    if position('insert into public.loyalty_programs(' in v_source) > 0 then
      raise notice 'v277: % already seeds loyalty_programs - skipped', v_target;
      continue;
    end if;

    v_hits := (length(v_source) - length(replace(v_source, v_declare_needle, '')))
              / length(v_declare_needle);
    if v_hits <> 1 then
      raise exception 'v277: expected exactly 1 declare needle in %, found %', v_target, v_hits;
    end if;

    v_hits := (length(v_source) - length(replace(v_source, v_seed_needle, '')))
              / length(v_seed_needle);
    if v_hits <> 1 then
      raise exception 'v277: expected exactly 1 subscriptions needle in %, found %', v_target, v_hits;
    end if;

    if position('v_v277_prior_sub' in v_source) > 0 then
      raise exception 'v277: % already declares the v277 claim snapshot but has no seed', v_target;
    end if;
    if position('v_owner' in v_source) = 0 then
      raise exception 'v277: % has no v_owner variable to impersonate', v_target;
    end if;

    v_patched := replace(v_source, v_declare_needle, v_declare_patch);
    v_patched := replace(v_patched, v_seed_needle, v_seed_patch);
    v_patched := replace(v_patched, v_stale_note, v_fresh_note);
    execute v_patched;

    -- Verify against the DEPLOYED definition, not the string just built: a CREATE OR REPLACE that
    -- landed on some other overload is exactly the failure this guards.
    v_source := pg_get_functiondef(v_target::regprocedure);
    if position('insert into public.loyalty_programs(' in v_source) = 0 then
      raise exception 'v277: the loyalty seed did not land in the deployed %', v_target;
    end if;
    if position('if app.c45_owner_loyalty_write(v_business.id) then' in v_source) = 0 then
      raise exception 'v277: the C45 gate did not land in the deployed %', v_target;
    end if;
    if position('v_v277_prior_claims text:=current_setting' in v_source) = 0 then
      raise exception 'v277: the claim snapshot did not land in the deployed %', v_target;
    end if;
    v_patched_count := v_patched_count + 1;
  end loop;

  raise notice 'v277: % activation function(s) now seed the loyalty preset', v_patched_count;
end
$v277$;

-- =================================================================================================
-- 2. Re-assert the execute privileges explicitly.
--
-- CREATE OR REPLACE FUNCTION preserves the existing ACL, so this is belt-and-braces rather than
-- repair — but it is stated here so the granted surface of a replaced SECURITY DEFINER function is
-- visible in the migration itself rather than inferred. The pre-change ACL of BOTH functions was
-- {postgres=X, authenticated=X, service_role=X}: PUBLIC and anon deliberately absent, because both
-- entry points self-check app.is_super_admin() and must never be reachable unauthenticated.
-- =================================================================================================
revoke all on function public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)
  from public;
revoke all on function public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)
  from anon;
grant execute on function public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)
  to postgres, authenticated, service_role;

revoke all on function public.platform_activate_approved_application_v169(uuid,uuid) from public;
revoke all on function public.platform_activate_approved_application_v169(uuid,uuid) from anon;
grant execute on function public.platform_activate_approved_application_v169(uuid,uuid)
  to postgres, authenticated, service_role;

-- =================================================================================================
-- 3. Backfill the tenants that were activated without a seed.
-- =================================================================================================
do $v277b$
declare
  v_row record;
  v_prior_sub text := current_setting('request.jwt.claim.sub', true);
  v_prior_claims text := current_setting('request.jwt.claims', true);
  v_seeded integer := 0;
  v_skipped text := '';
  v_ok boolean;
begin
  for v_row in
    select business.id,
           business.name,
           (select staff_row.user_id
              from public.staff staff_row
             where staff_row.business_id = business.id
               and staff_row.role = 'owner'
               and staff_row.active
               and staff_row.access_state = 'approved'
             order by staff_row.created_at asc, staff_row.id asc
             limit 1) as owner_user_id
      from public.businesses business
      join public.business_workspace_controls_v94 control
        on control.business_id = business.id
     where control.approval_status = 'approved'
       and not exists (select 1 from public.loyalty_programs program
                        where program.business_id = business.id)
       and not exists (select 1 from public.firm_config_versions version
                        where version.business_id = business.id)
     order by business.created_at asc
  loop
    if v_row.owner_user_id is null then
      v_skipped := v_skipped || v_row.id::text || ' (no approved active owner); ';
      continue;
    end if;

    -- Same impersonation as the function change: publish the owner's claims, seed once, restore.
    perform set_config('request.jwt.claim.sub', v_row.owner_user_id::text, true);
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_row.owner_user_id, 'role', 'authenticated',
                         'aud', 'authenticated')::text, true);
    v_ok := app.c45_owner_loyalty_write(v_row.id);
    if v_ok then
      insert into public.loyalty_programs(
        business_id, kind, earn_points_per_dollar, redeem_points,
        reward_credit_cents, active, loyalty_model, configuration_status,
        recommendation_source
      ) values (
        v_row.id, 'points', 1, 800, 2000, false, 'classic', 'draft',
        'onboarding_preset'
      ) on conflict (business_id) do nothing;
    end if;
    perform set_config('request.jwt.claim.sub', coalesce(v_prior_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);

    if not v_ok then
      v_skipped := v_skipped || v_row.id::text || ' (c45_owner_loyalty_write false); ';
      continue;
    end if;

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (
      v_row.id, null, 'ACTIVATION_LOYALTY_SEED_BACKFILL_V277', 'loyalty_programs', v_row.id,
      jsonb_build_object(
        'reason', 'super-admin activation (v105/v169) shipped this workspace with no loyalty base',
        'seeded_as_owner', v_row.owner_user_id,
        'preset', 'points/1/800/2000/classic/draft/inactive'
      )
    );
    v_seeded := v_seeded + 1;
  end loop;

  -- A tenant selected above but still unseeded means the fix did not work; fail loudly rather
  -- than commit a half-done backfill.
  if v_skipped <> '' then
    raise exception 'v277: backfill could not seed: %', v_skipped;
  end if;

  if exists (
    select 1
      from public.businesses business
      join public.business_workspace_controls_v94 control
        on control.business_id = business.id
     where control.approval_status = 'approved'
       and not exists (select 1 from public.loyalty_programs program
                        where program.business_id = business.id)
       and not exists (select 1 from public.firm_config_versions version
                        where version.business_id = business.id)
  ) then
    raise exception 'v277: an approved workspace is still without a loyalty base after backfill';
  end if;

  raise notice 'v277: backfilled % approved workspace(s) with the loyalty preset', v_seeded;
end
$v277b$;

commit;
