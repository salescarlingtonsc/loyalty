-- Rollback-only acceptance for V276 — the programme recommender learns the bar sector.
--
-- Runs against the REAL production schema inside ONE transaction and ends in ROLLBACK: nothing
-- it writes survives. The fixture is the long-standing QA tenant "QA Test Cafe"
-- (dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf), chosen because it is the only open tenant that has a
-- published loyalty configuration AND zero open drafts — and an open draft is not incidental
-- here: generate_retention_recommendation deliberately RESUMES an existing draft instead of
-- generating, so a fixture with drafts would short-circuit every assertion below into the
-- 'existing_draft' branch and prove nothing. Its industry is flipped per case, exactly the way
-- v275_bar_bottle_keep.sql borrows a tenant, because the sector is the input under test.
--
-- What this proves, in order:
--   1  The deployed recommender carries the bar sector in the points_tiers CASE list and the
--      bar-only tier_basis expression — i.e. the migration landed on the live function object,
--      not on a copy.
--   2  NO OTHER SECTOR MOVED. The fnb -> stamps branch is byte-identical, and the classic
--      fallback still exists.
--   3  fnb still recommends 'stamps', and its draft's tier_basis is inherited from the base
--      version rather than overwritten.
--   4  bar recommends 'points_tiers' AND the draft is written with tier_basis='spend' — the
--      owner's stated VIP model for bars (V275 design §3.3: "VIP feel comes from tiers based on
--      spending").
--   5  salon still recommends 'points_tiers' and its tier_basis is still INHERITED, proving the
--      'spend' write is bar-only and did not leak into the sectors that were already handled.
--   6  'other' still falls through to 'classic'.
--
-- Between cases the produced draft is detached from the base version (based_on_version_id set to
-- null) rather than deleted: every child of firm_config_versions is ON DELETE RESTRICT, and the
-- only thing the next case needs is for the base to have no draft hanging off it.
--
-- Client-side sector behaviour is pinned by tests/business-ui/v276-bar-sector-polish.test.mjs.

begin;

create or replace function pg_temp.as_v276_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  reset role;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v276_user(uuid, text) to public;

do $v276$
declare
  v_biz uuid := 'dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf';
  v_owner uuid;
  v_industry_before text;
  v_base uuid;
  v_base_basis text;
  v_source text;
  v_result json;
  v_draft uuid;
  v_model text;
  v_basis text;
  v_drafts integer;
begin
  ---------------------------------------------------------------------------------------------
  -- 1 + 2. The deployed function object.
  ---------------------------------------------------------------------------------------------
  v_source := pg_get_functiondef(
    'public.generate_retention_recommendation(uuid,text)'::regprocedure);

  if position($n$in ('salon','spa','facial','massage','fitness','retail','bar') then 'points_tiers'$n$
              in v_source) = 0 then
    raise exception 'v276.1: the deployed recommender does not list the bar sector under points_tiers';
  end if;
  if position($n$'tier_basis',case when lower(coalesce(v_business.industry,''))='bar' then 'spend' else null end$n$
              in v_source) = 0 then
    raise exception 'v276.1: the deployed recommender does not write tier_basis for a bar';
  end if;
  if position($n$in ('fnb','food_beverage','cafe','restaurant') then 'stamps'$n$
              in v_source) = 0 then
    raise exception 'v276.2: the fnb -> stamps branch was altered';
  end if;
  if position($n$else 'classic'$n$ in v_source) = 0 then
    raise exception 'v276.2: the classic fallback was altered';
  end if;

  ---------------------------------------------------------------------------------------------
  -- Fixture.
  ---------------------------------------------------------------------------------------------
  select business.industry, coalesce(business.active_config_version_id,
           (select program.current_config_version_id from public.loyalty_programs program
             where program.business_id = v_biz))
    into v_industry_before, v_base
    from public.businesses business where business.id = v_biz;
  if v_industry_before is null then
    raise exception 'v276: fixture tenant % not found', v_biz;
  end if;
  if v_base is null then
    raise exception 'v276: fixture tenant has no published loyalty configuration';
  end if;

  select count(*) into v_drafts from public.firm_config_versions version
   where version.business_id = v_biz and version.status = 'draft'
     and version.based_on_version_id = v_base;
  if v_drafts <> 0 then
    raise exception 'v276: fixture already has % draft(s) on the base version - the recommender would resume instead of generate', v_drafts;
  end if;

  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   limit 1;
  if v_owner is null then
    raise exception 'v276: fixture needs an approved active owner';
  end if;

  select programme.tier_basis into v_base_basis
    from public.loyalty_program_versions programme
   where programme.config_version_id = v_base and programme.business_id = v_biz;

  -- SCAFFOLDING (found when this suite was first run against prod, 2026-08-11). The fixture's
  -- sector cannot simply be UPDATEd any more: app.business_sector_modules_guard_v75 is a BEFORE
  -- UPDATE trigger on businesses that raises 42501 whenever industry OR enabled_modules changes
  -- on a tenant that has a row in business_sector_assignments — modules are pinned by the sector
  -- entitlement. The guard's OWN documented escape hatch is the transaction-local GUC
  -- app.sector_entitlement_sync, which the entitlement-sync path sets to the business id; using
  -- it here is what that hatch is for, and every flip it permits is undone by the ROLLBACK below.
  -- Without this line the suite dies at case 4, because the fixture's stored industry is already
  -- 'fnb' (case 3 is a no-op update the guard never sees) and 'bar' is the first real change.
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);

  ---------------------------------------------------------------------------------------------
  -- 3. fnb — unchanged: stamps, and tier_basis inherited.
  ---------------------------------------------------------------------------------------------
  update public.businesses set industry = 'fnb' where id = v_biz;
  perform pg_temp.as_v276_user(v_owner);
  v_result := public.generate_retention_recommendation(v_biz, 'v276-fnb-' || gen_random_uuid()::text);
  reset role;
  v_model := v_result->>'model';
  v_draft := (v_result->>'draft_config_version_id')::uuid;
  if v_model <> 'stamps' then
    raise exception 'v276.3: fnb recommended % instead of stamps', v_model;
  end if;
  select programme.tier_basis into v_basis from public.loyalty_program_versions programme
   where programme.config_version_id = v_draft;
  if v_basis is distinct from v_base_basis then
    raise exception 'v276.3: fnb draft tier_basis moved from % to %', v_base_basis, v_basis;
  end if;
  update public.firm_config_versions set based_on_version_id = null where id = v_draft;

  ---------------------------------------------------------------------------------------------
  -- 4. bar — the change under test: points_tiers, and tier_basis written as 'spend'.
  ---------------------------------------------------------------------------------------------
  update public.businesses set industry = 'bar' where id = v_biz;
  perform pg_temp.as_v276_user(v_owner);
  v_result := public.generate_retention_recommendation(v_biz, 'v276-bar-' || gen_random_uuid()::text);
  reset role;
  v_model := v_result->>'model';
  v_draft := (v_result->>'draft_config_version_id')::uuid;
  if v_model <> 'points_tiers' then
    raise exception 'v276.4: bar recommended % instead of points_tiers', v_model;
  end if;
  if (v_result->'input_metrics'->>'industry') <> 'bar' then
    raise exception 'v276.4: the run did not record the bar sector in its input metrics';
  end if;
  select programme.tier_basis into v_basis from public.loyalty_program_versions programme
   where programme.config_version_id = v_draft;
  if v_basis is distinct from 'spend' then
    raise exception 'v276.4: bar draft tier_basis is % instead of spend', coalesce(v_basis, 'null');
  end if;
  update public.firm_config_versions set based_on_version_id = null where id = v_draft;

  ---------------------------------------------------------------------------------------------
  -- 5. salon — already a points_tiers sector, and it must NOT have gained the 'spend' write.
  ---------------------------------------------------------------------------------------------
  update public.businesses set industry = 'salon' where id = v_biz;
  perform pg_temp.as_v276_user(v_owner);
  v_result := public.generate_retention_recommendation(v_biz, 'v276-salon-' || gen_random_uuid()::text);
  reset role;
  v_model := v_result->>'model';
  v_draft := (v_result->>'draft_config_version_id')::uuid;
  if v_model <> 'points_tiers' then
    raise exception 'v276.5: salon recommended % instead of points_tiers', v_model;
  end if;
  select programme.tier_basis into v_basis from public.loyalty_program_versions programme
   where programme.config_version_id = v_draft;
  if v_basis is distinct from v_base_basis then
    raise exception 'v276.5: salon draft tier_basis moved from % to % - the bar-only write leaked',
      coalesce(v_base_basis, 'null'), coalesce(v_basis, 'null');
  end if;
  update public.firm_config_versions set based_on_version_id = null where id = v_draft;

  ---------------------------------------------------------------------------------------------
  -- 6. other — still the classic fallback.
  ---------------------------------------------------------------------------------------------
  update public.businesses set industry = 'other' where id = v_biz;
  perform pg_temp.as_v276_user(v_owner);
  v_result := public.generate_retention_recommendation(v_biz, 'v276-other-' || gen_random_uuid()::text);
  reset role;
  v_model := v_result->>'model';
  if v_model <> 'classic' then
    raise exception 'v276.6: other recommended % instead of classic', v_model;
  end if;

  raise notice 'v276: all assertions passed (the fixture industry is restored by ROLLBACK)';
end
$v276$;

rollback;
