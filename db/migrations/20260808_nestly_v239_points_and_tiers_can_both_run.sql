-- V239 — a firm may run points redemption AND tiered membership at the same time.
--
-- Owner, with Chagee as the reference: "we can allow 2 ongoing rewards (points & tier);
-- tier is by number of visits while points is for redemption."
--
-- V229 made the two exclusive because points doing double duty is genuinely incoherent: if
-- the same points both buy rewards and decide the tier, spending them should cost the
-- customer their status. Chagee sidesteps that by earning the tier from CUPS (visits) and
-- keeping points ("tea leaves") as an independent spendable currency. Nothing clashes,
-- because nothing is shared.
--
-- So the exclusivity was never really about points-vs-tiers — it was about the tier being
-- MEASURED IN POINTS. This migration encodes exactly that:
--   * points_mode gains 'both'
--   * a firm in 'both' may not measure its tier in points (that is the incoherent case)
--   * the redemption gate in customer_create_redemption_intent_v89 still refuses only
--     'tiers', so 'both' redeems normally — that function is deliberately not touched.
begin;

alter table public.businesses drop constraint if exists businesses_points_mode_check;
alter table public.businesses add constraint businesses_points_mode_check
  check (points_mode is null or points_mode = any (array['redeem','tiers','both']));

-- The rule is a cross-table invariant (points_mode on businesses, tier_basis on
-- loyalty_programs), so a CHECK cannot express it. Guard both write paths instead, and
-- state the fix in the error rather than leaving the owner to guess.
--
-- V239a: the first cut read new.business_id unconditionally, which does not exist on
-- businesses (its key is id). plpgsql resolves both arms of a coalesce, so the trigger threw
-- 42703 on every points_mode write. The business id is resolved inside the table branch.
create or replace function app.v239_guard_points_and_tier_basis()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_business uuid;
  v_mode text;
  v_basis text;
begin
  if tg_table_name = 'businesses' then
    v_business := new.id;
    v_mode := new.points_mode;
    select lp.tier_basis into v_basis from public.loyalty_programs lp
     where lp.business_id = v_business limit 1;
  else
    v_business := new.business_id;
    v_basis := new.tier_basis;
    select b.points_mode into v_mode from public.businesses b
     where b.id = v_business;
  end if;
  if v_mode = 'both' and v_basis = 'points_earned' then
    raise exception 'a programme that redeems points cannot also measure its tiers in points — set the tier to visits or spend'
      using errcode='23514';
  end if;
  return new;
end
$function$;

drop trigger if exists v239_guard_points_mode on public.businesses;
create trigger v239_guard_points_mode
  before update of points_mode on public.businesses
  for each row execute function app.v239_guard_points_and_tier_basis();

drop trigger if exists v239_guard_tier_basis on public.loyalty_programs;
create trigger v239_guard_tier_basis
  before insert or update of tier_basis on public.loyalty_programs
  for each row execute function app.v239_guard_points_and_tier_basis();

commit;
