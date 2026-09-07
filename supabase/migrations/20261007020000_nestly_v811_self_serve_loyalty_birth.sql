/* nestly_v811 — a self-serve tenant is born with its loyalty row, or it is not born at all.

   THE DEFECT (tenant divergence scan D11, "stranded birth", 3 live tenants).

   Three paying production firms — Cafe 111 (1c1c2a34-cb6e-4686-8bb0-b94d6102656a), Cafe 312
   (61e27c61-1625-454c-a1bb-0ec6c4a0a682) and cs cafe on (619b2bfb-53c8-40ff-b808-e820d06e2eac),
   all born 2026-09-05 — have the loyalty module ON, an approved workspace, a paid annual
   subscription, an owner login, a default branch and four business_programmes rows, and:

     zero public.loyalty_programs rows,
     zero public.firm_config_versions rows,
     businesses.active_config_version_id = NULL.

   That is the exact state nestly_v565 named and repaired for two other tenants: with no
   loyalty_programs row there is no version 1, so public.create_loyalty_config_draft resolves no
   base version and raises 'base configuration not found'. The firm can never open Grow. Every
   versioned reader — rewards, tiers, stamps, birthday, retention — resolves to nothing.

   THE DEFECT CLASS, not the three rows.

   nestly_v565's ruling was "every business is born the same": app.ensure_loyalty_program_row is
   THE one birth of that row — idempotent, definer, ungated, carrying the full onboarding preset
   (points, earn 1, redeem 800, reward credit 2000c, inactive, classic, draft) — and every ad-hoc
   bootstrapper was pointed at it precisely because two of them "inserted it only if
   app.c45_owner_loyalty_write said yes and SILENTLY SKIPPED it otherwise".

   nestly_v763 built the self-serve activation path after that ruling and did not follow it. Read
   from production 2026-10-07, app.self_serve_activation_apply_v763 carries its own copy of the
   preset behind exactly the guard v565 removed everywhere else:

       if app.c45_owner_loyalty_write(p_business) then
       insert into public.loyalty_programs(...) values(...) on conflict(business_id) do nothing;
       end if;

   It is the ONLY remaining path in the estate that can decline to seed the row and say nothing.
   (Scanned: public.activate_approved_business_application_v95 inserts unconditionally;
   platform_decide_business_application_v105, platform_activate_approved_application_v169,
   business_set_tier_basis_v347, business_set_loyalty_model_v353, business_set_earning_rule_v359
   and create_loyalty_config_draft all call app.ensure_loyalty_program_row.)

   WHY THE GUARD SAID NO — and why the answer does not change the fix.

   app.c45_owner_loyalty_write asks app.can_module_write -> app.staff_module_mode_v94, whose FIRST
   test is app.business_workspace_open_v94 -> app.business_operational_v620:

       control.approval_status = 'approved' and not lifecycle.workspace_paused

   Both of those are RUNTIME STATE being written during the very transaction that is trying to ask
   the question: this function approves the workspace control a few statements earlier, and
   business_subscription_lifecycle_v94.workspace_paused belongs to the billing lifecycle, written
   by other triggers on the same provider evidence. Two firms activated through the identical code
   in the same 27-hour window (Cafe Only, 2026-09-05 03:58; Hairdressing @ Choa Chu Kang,
   2026-09-06 07:38) DID get the row; the three above, activated between them at 07:40, 09:25 and
   09:59 on 2026-09-05, did not — same sector bundle, same module list, same owner shape, same
   tier. Evaluated against production TODAY the guard answers true for all five, so the exact
   state that flipped it is no longer recoverable from the record.

   That is the point. The birth of a tenant's system-of-record row must not be conditional on a
   permission question about a workspace that is being opened in the same breath, because the
   answer is a race and the losing branch is silent. v565 ruled on this once; this migration makes
   the last path obey it, so the question is never asked again.

   THE FIX — three lines of behaviour.

   1. app.self_serve_activation_apply_v763's guarded private insert becomes
        perform app.ensure_loyalty_program_row(p_business, 'self_service_onboarding_preset');
      The preset values are byte-identical to the ones the private insert used (compared against
      the live app.ensure_loyalty_program_row body), so nothing about a successfully-seeded tenant
      changes; what changes is that an unsuccessful one is now impossible. The temporary owner
      claims around the seed are LEFT IN PLACE unchanged: app.seed_loyalty_config_version records
      auth.uid() as firm_config_versions.created_by, and the healthy tenants carry the owner
      there. This migration touches ONE statement.

   2. The splice is done with pg_get_functiondef + an anchor that must match exactly once, so a
      drifted body fails loudly instead of being silently reverted to a stale copy, and re-running
      the migration is a no-op (the 'already delegates' notice).

   3. BACKFILL, after the writer is closed and only then, for the exact stranded shape: a business
      with a self_serve_business_onboarding_v130 row in status 'active' and no loyalty_programs
      row. It writes the SAME default that path now writes, through the same one authority, under
      the same owner identity, so the repaired tenants are indistinguishable from Cafe Only. No
      programme values are invented: app.seed_loyalty_config_version (v507, "born live") then
      creates firm_config_versions v1 published with source 'self_service_onboarding_preset' and
      claims businesses.active_config_version_id, exactly as it did for the two healthy firms.
      Idempotent by the NOT EXISTS and by ensure_loyalty_program_row's ON CONFLICT DO NOTHING.

   NOT CHANGED HERE, on purpose: app.c45_owner_loyalty_write itself (it is the correct guard for a
   MERCHANT writing loyalty configuration through a session, and other callers rely on it);
   app.ensure_loyalty_program_row; the seed trigger; the tier/price/evidence checks above the seed;
   and every early return in the activation function — a firm whose paid evidence does not match
   its tier still does not activate, and still gets no loyalty row, which is correct.

   EXPOSURE STATEMENT ⚖️ — no data was exposed and no permission is widened. The seed is a write
   of a firm's OWN default configuration row, performed by a SECURITY DEFINER function the same
   transaction already invoked under the same owner identity; app.ensure_loyalty_program_row has
   EXECUTE for postgres only ({postgres=X/postgres}) and gains no grant here. The change removes a
   guard from a system write, not from a caller: no session, role or tenant can reach anything it
   could not reach before.

   PROOFS in the header, all read-only against production (gadpooereceldfpfxsod) 2026-10-07:
     * the three stranded tenants and their two healthy siblings — see the D11 body above;
     * the live app.self_serve_activation_apply_v763 body carrying the guarded insert;
     * app.ensure_loyalty_program_row's preset, identical to the private one;
     * the estate scan showing every OTHER birth path already delegates.

   ROLLBACK SUITE: db/tests/v811_self_serve_loyalty_birth.sql (and the executed copy).
   REVERSIBLE: re-splice the anchor back (restore the `if app.c45_owner_loyalty_write(...) then`
   block from db/migrations/20261002_nestly_v766_self_serve_activation_tier_price.sql). The
   backfilled rows are ordinary tenant configuration and are not undone by that.
*/

begin;

set search_path to 'pg_catalog','public','app','pg_temp';

-- =============================================================================================
-- PRECONDITIONS — the shapes this migration expects to find.
-- =============================================================================================
do $pre$
begin
  if to_regprocedure('app.self_serve_activation_apply_v763(uuid,text,timestamptz)') is null then
    raise exception 'nestly_v811: app.self_serve_activation_apply_v763 is missing'
      using errcode = 'XX001';
  end if;
  if to_regprocedure('app.ensure_loyalty_program_row(uuid,text)') is null then
    raise exception 'nestly_v811: app.ensure_loyalty_program_row (nestly_v565) is missing — the '
                    'one birth of the loyalty row must exist before a path can be pointed at it'
      using errcode = 'XX001';
  end if;
  -- The helper must still write the preset the private insert wrote, or delegating would change
  -- what a self-serve tenant is born with.
  if position('p_business,''points'',1,800,2000,false,''classic'',''draft'''
       in pg_get_functiondef('app.ensure_loyalty_program_row(uuid,text)'::regprocedure)) = 0 then
    raise exception 'nestly_v811: app.ensure_loyalty_program_row no longer writes the v565 preset '
                    '— re-derive this migration from the live body'
      using errcode = 'XX001';
  end if;
end
$pre$;

-- =============================================================================================
-- 1. THE WRITER. One birth of the loyalty row, on the self-serve path too.
-- =============================================================================================
do $splice$
declare
  v_def text;
  v_new text;
  -- ONE E-string on purpose: adjacent literals in Postgres each keep their own escape rules, so
  -- a continuation line written as a plain '...\n' would contribute a literal backslash-n and the
  -- anchor could never match.
  v_anchor constant text := E'  if app.c45_owner_loyalty_write(p_business) then\n  insert into public.loyalty_programs(\n    business_id,kind,earn_points_per_dollar,redeem_points,\n    reward_credit_cents,active,loyalty_model,configuration_status,\n    recommendation_source\n  ) values(\n    p_business,''points'',1,800,2000,false,''classic'',''draft'',\n    ''self_service_onboarding_preset''\n  ) on conflict(business_id) do nothing;\n  end if;\n';
  v_replacement constant text :=
E'  perform app.ensure_loyalty_program_row(p_business, ''self_service_onboarding_preset'');\n';
begin
  v_def := pg_get_functiondef(
    'app.self_serve_activation_apply_v763(uuid,text,timestamptz)'::regprocedure);
  if position('ensure_loyalty_program_row' in v_def) > 0 then
    raise notice 'nestly_v811: self_serve_activation_apply_v763 already delegates the loyalty '
                 'birth to app.ensure_loyalty_program_row, skipping the splice';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor), 0) <> 1
    then
      raise exception 'nestly_v811: the guarded loyalty-seed anchor did not match exactly once in '
                      'self_serve_activation_apply_v763 — body drifted, re-derive from live'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_replacement);
    if v_new = v_def then
      raise exception 'nestly_v811: splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;

-- The ACL is restated rather than assumed. Read from production 2026-10-07 this function's proacl
-- is {postgres=X/postgres} — no role but the owner may execute it, and CREATE OR REPLACE above
-- preserved that. Restating makes the intent explicit and survives a future re-emission.
revoke all on function app.self_serve_activation_apply_v763(uuid,text,timestamptz)
  from public, anon, authenticated, service_role;

-- =============================================================================================
-- 2. THE BACKFILL — after the writer is closed, and only for the stranded shape.
-- =============================================================================================
do $backfill$
declare
  r record;
  v_prior_sub text := current_setting('request.jwt.claim.sub', true);
  v_prior_claims text := current_setting('request.jwt.claims', true);
  v_repaired integer := 0;
begin
  for r in
    select onboarding.business_id, onboarding.owner_user_id
      from public.self_serve_business_onboarding_v130 onboarding
     where onboarding.status = 'active'
       and not exists (select 1 from public.loyalty_programs lp
                        where lp.business_id = onboarding.business_id)
     order by onboarding.business_id
  loop
    -- The same identity the live path lends the seed, so firm_config_versions.created_by names
    -- the firm's owner exactly as it does on a tenant that was born correctly.
    perform set_config('request.jwt.claim.sub', coalesce(r.owner_user_id::text, ''), true);
    perform set_config('request.jwt.claims',
      case when r.owner_user_id is null then ''
           else jsonb_build_object('sub', r.owner_user_id,
                                   'role', 'authenticated',
                                   'aud', 'authenticated')::text end, true);
    perform app.ensure_loyalty_program_row(r.business_id, 'self_service_onboarding_preset');
    perform set_config('request.jwt.claim.sub', coalesce(v_prior_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (r.business_id, null, 'LOYALTY_ROW_BACKFILLED_V811', 'loyalty_programs',
            r.business_id,
            jsonb_build_object(
              'reason', 'stranded birth: self-serve activation skipped the loyalty seed',
              'source', 'self_service_onboarding_preset',
              'writer_closed_by', 'nestly_v811'));
    v_repaired := v_repaired + 1;
  end loop;
  raise notice 'nestly_v811: repaired % stranded self-serve tenant(s)', v_repaired;
end
$backfill$;

-- =============================================================================================
-- 3. VERIFY, in the same transaction. Any failure rolls the whole migration back.
-- =============================================================================================
do $verify$
declare
  v_def text;
  v_left integer;
  v_no_version integer;
begin
  v_def := pg_get_functiondef(
    'app.self_serve_activation_apply_v763(uuid,text,timestamptz)'::regprocedure);

  if position('ensure_loyalty_program_row' in v_def) = 0 then
    raise exception 'nestly_v811 VERIFY: the self-serve path still does not delegate the loyalty '
                    'birth' using errcode = 'XX001';
  end if;
  if position('if app.c45_owner_loyalty_write(p_business) then' in v_def) > 0 then
    raise exception 'nestly_v811 VERIFY: the guarded private insert survived the splice'
      using errcode = 'XX001';
  end if;
  -- The rest of the activation contract is untouched: the tier/evidence refusals and the owner
  -- requirement are still there, so this migration cannot have activated anything it should not.
  if position('paid_evidence_does_not_match_tier_terms' in v_def) = 0
     or position('no_active_owner' in v_def) = 0
     or position('no_payment_pending_onboarding' in v_def) = 0 then
    raise exception 'nestly_v811 VERIFY: an activation refusal was lost by the splice'
      using errcode = 'XX001';
  end if;

  select count(*) into v_left
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.status = 'active'
     and not exists (select 1 from public.loyalty_programs lp
                      where lp.business_id = onboarding.business_id);
  if v_left <> 0 then
    raise exception 'nestly_v811 VERIFY: % activated self-serve tenant(s) still have no '
                    'loyalty_programs row', v_left using errcode = 'XX001';
  end if;

  -- The seed trigger must have done the rest of the birth: version 1 published, pointer claimed.
  -- This is the D11 second disjunct, and it is what makes the repaired tenants non-divergent
  -- rather than merely half-repaired.
  select count(*) into v_no_version
    from public.self_serve_business_onboarding_v130 onboarding
    join public.businesses b on b.id = onboarding.business_id
   where onboarding.status = 'active'
     and (b.active_config_version_id is null
          or not exists (select 1 from public.firm_config_versions fcv
                          where fcv.business_id = b.id and fcv.version_no = 1));
  if v_no_version <> 0 then
    raise exception 'nestly_v811 VERIFY: % activated self-serve tenant(s) have a loyalty row but '
                    'no version 1 / no active_config_version_id', v_no_version
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
