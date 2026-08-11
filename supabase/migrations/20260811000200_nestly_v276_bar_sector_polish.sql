-- NESTLY v276 — BAR SECTOR POLISH: the programme recommender learns what a bar is
--
-- Owner, 2026-08-11, after creating the first real bar tenant ("Bistro 999") and signing in:
-- "i dont see the full suite of modules ready for production - please plan and analyse and only
-- come back when you're ready."
--
-- V275 added the 'bar' sector, its module bundle and bottle keep. It did NOT teach the one place
-- in SQL that still branches on sector: public.generate_retention_recommendation, whose industry
-- CASE lists 'fnb'/'cafe'/'restaurant' (-> stamps) and 'salon'/'spa'/'facial'/'massage'/
-- 'fitness'/'retail' (-> points_tiers) and sends everything else to 'classic'. A bar therefore
-- got the "limited catalog signal" fallback: plain points, no tier ladder, and the rationale
-- string that apologises for not knowing the sector.
--
-- The V275 design document (docs/design/V275-BAR-BOTTLE-KEEP-DESIGN.md §3.3, §3.4) states the
-- owner's model for bars explicitly: VIP feel comes from TIERS BASED ON SPENDING, and the
-- recommender should propose points_tiers with tier_basis='spend'. That is what this migration
-- makes true, and it is the only sector-shaped behaviour left in the database.
--
-- WHY tier_basis='spend' AND NOT 'visits' FOR A BAR. A bar's regulars are separated by what they
-- order, not by how often they walk in — the customer who buys a bottle to park and the customer
-- who buys one beer both register one visit, and ranking them equally is the opposite of a VIP
-- programme. Spend is also the basis the bottle-keep integration already moves for free: a parked
-- bottle is bought through an ordinary sale, so the tier climbs with no new plumbing (V275,
-- owner amendment 1). Only the BAR branch sets a basis; every other sector's draft keeps whatever
-- basis it already had, because save_loyalty_config_draft coalesces a NULL back to the stored
-- value.
--
-- HOW THIS IS WRITTEN, AND WHY. The function is ~180 lines of settled logic that has been amended
-- by V128, V197 and V258; retyping it to change two lines would be the riskiest possible way to
-- change two lines. So the migration reads the function's OWN deployed source, splices the two
-- fragments, and re-executes it. Both needles are pure SQL — no comment text, no whitespace-
-- sensitive prose — because the MCP migration path strips comments and a comment-anchored needle
-- would silently miss (see the rehearsal-vs-prod note in the team memory). Each splice asserts
-- EXACTLY ONE occurrence before it runs and the result is verified afterwards, so the migration
-- either makes precisely the intended change or makes none at all.
--
-- Re-running is safe: if the sector list already carries 'bar' the migration reports it and
-- stops without touching anything.
--
-- NOT IN THIS MIGRATION, deliberately:
--   * the sector_bundle_versions row for 'bar'. Its published module list omits 'packages' while
--     the client-side sector map lists it; that is an ENTITLEMENT decision for the owner, not a
--     silent widening of a live tenant's plan, and it is reported rather than applied.
--   * anything about loyalty_tiers. Owner amendment 1 of V275 stands: the tier mechanism is the
--     existing one, and no bar-specific tier column exists anywhere.
--
-- Client-side sector behaviour (nav, seating, guided setup, reward templates, give-back band)
-- ships in app/app.js and is pinned by tests/business-ui/v276-bar-sector-polish.test.mjs.
-- Rollback-only acceptance for this file: db/tests/v276_bar_sector_polish.sql.

begin;

do $v276$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_sector_needle constant text :=
    $needle$in ('salon','spa','facial','massage','fitness','retail') then 'points_tiers'$needle$;
  v_sector_patch constant text :=
    $needle$in ('salon','spa','facial','massage','fitness','retail','bar') then 'points_tiers'$needle$;
  v_save_needle constant text :=
    $needle$'kind','points','active',v_base_active,'loyalty_model',v_model,$needle$;
  v_save_patch constant text :=
    $needle$'kind','points','active',v_base_active,'loyalty_model',v_model,
    'tier_basis',case when lower(coalesce(v_business.industry,''))='bar' then 'spend' else null end,$needle$;
begin
  v_source := pg_get_functiondef(
    'public.generate_retention_recommendation(uuid,text)'::regprocedure);

  if position(v_sector_patch in v_source) > 0 then
    raise notice 'v276: generate_retention_recommendation already knows the bar sector - nothing to do';
    return;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_sector_needle, '')))
            / length(v_sector_needle);
  if v_hits <> 1 then
    raise exception 'v276: expected exactly 1 sector-CASE needle in generate_retention_recommendation, found %', v_hits;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_save_needle, '')))
            / length(v_save_needle);
  if v_hits <> 1 then
    raise exception 'v276: expected exactly 1 draft-save needle in generate_retention_recommendation, found %', v_hits;
  end if;

  v_patched := replace(v_source, v_sector_needle, v_sector_patch);
  v_patched := replace(v_patched, v_save_needle, v_save_patch);
  execute v_patched;

  -- Verify against the DEPLOYED definition, not against the string we just built: a CREATE OR
  -- REPLACE that silently landed somewhere else is exactly the failure this guards.
  v_source := pg_get_functiondef(
    'public.generate_retention_recommendation(uuid,text)'::regprocedure);
  if position(v_sector_patch in v_source) = 0 then
    raise exception 'v276: the bar sector did not land in the deployed recommender';
  end if;
  if position($check$'tier_basis',case when lower(coalesce(v_business.industry,''))='bar'$check$
              in v_source) = 0 then
    raise exception 'v276: the bar tier_basis did not land in the deployed recommender';
  end if;
  raise notice 'v276: generate_retention_recommendation now recommends points_tiers + spend tiers for a bar';
end
$v276$;

commit;
