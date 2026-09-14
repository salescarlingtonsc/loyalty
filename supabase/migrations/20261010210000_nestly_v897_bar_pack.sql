-- NESTLY v897 — a bar is an F&B business, so its drinks map themselves too.
--
-- BLIND SPOT FOUND IN PRODUCTION after nestly_v895 was applied (2026-10-07). v895's backfill
-- mapped 22 of the estate's services and left 11 behind. Five of those were a tenant data-entry
-- matter we leave alone, three genuinely match nothing and one is ambiguous — but the shape of
-- the miss pointed at the resolver itself: app.business_pack_v648 (nestly_v648) knows only four
-- industries, and `bar` is not one of them.
--
--   case industry when 'fnb' then 'fnb' when 'salon' then 'hair_salon'
--                 when 'facial' then 'beauty_wellness' when 'massage' then 'beauty_wellness'
--                 else 'generic' end
--
-- The app offers EIGHT industries (app/app.js INDUSTRIES: salon, facial, massage, fitness, fnb,
-- bar, retail, other). A bar therefore fell through to 'generic', and under v895's pack rule
-- every beverage and food keyword it matched came back `cross_pack` — suggested on the board,
-- never auto-applied. Two live businesses are in that state (Bistro 999, HENG HENG 888), and
-- their catalogues are drinks and food: exactly the pack the resolver refused to give them.
--
-- THE CHANGE IS ONE CASE BRANCH: `when 'bar' then 'fnb'`. A bar sells the same things a cafe
-- sells — v275 already says so on the client side, where the bar module bundle is the F&B bundle
-- plus bottle keep, packages and memberships. The other three industries stay 'generic' ON
-- PURPOSE, and this is the ruling, not an omission:
--   · fitness — classes, sessions and memberships; the generic pack's class_course /
--     session_service / consultation nodes are what its catalogue actually is. Neither
--     beauty_wellness nor fnb would be more right, and a wrong pack is worse than none, because
--     the pack rule is what turns a match into an automatic mapping.
--   · retail  — goods, not services; generic.retail_product is the honest node.
--   · other   — by definition unknown; 'generic' is the only defensible answer.
-- When one of those three earns its own pack it will be a taxonomy_versions decision (a new
-- version plus carry-map rows, per v647), not another branch bolted onto this case.
--
-- SIX BAR KEYWORDS. The resolver alone does not finish the job: a bar's commonest line is a
-- draught beer, and v647/v895 spelled only 'draft beer'. 'draught' (the spelling used on every
-- Singapore bar menu), 'draught beer', 'pint', 'lager', 'stout' and 'bottle beer' join
-- beverages.alcohol. All six are ≥3 characters of [a-z0-9 '-] and none is a word another pack's
-- service names carry; 'ale' was considered and REJECTED, because word-start matching would let
-- it open any name beginning "ale…".
--
-- THEN THE BACKFILL RUNS AGAIN. app.service_automap_backfill_v895() is idempotent by
-- construction (confident-only, insert-where-absent, ON CONFLICT DO NOTHING), so calling it here
-- takes the bar tenants' newly-own-pack matches and touches nothing else. Nothing is ever
-- overwritten: an owner_chosen, console_corrected or accepted_suggestions mapping — and any
-- automatic one already written — survives untouched.
--
-- GRANTS. app.business_pack_v648 is re-emitted, not created: nestly_v648 gave it no explicit
-- ACL, so it carries PostgreSQL's default (EXECUTE to PUBLIC) in production today and
-- CREATE OR REPLACE preserves that. This migration deliberately states no revoke/grant for it
-- rather than inventing a narrower ACL the function has never had — narrowing it is a separate
-- decision with its own blast radius (every non-definer reader of the pack), not a side effect
-- of adding an industry.
--
-- Rollback suite: db/tests/v897_corpus_bar_pack.sql (also db/tests/executed/).
begin;

-- =============================================================================================
-- 1. The resolver learns the industry the app has offered since v275.
-- =============================================================================================
create or replace function app.business_pack_v648(p_business uuid)
returns text
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case coalesce((select b.industry from public.businesses b where b.id = p_business), 'other')
    when 'fnb' then 'fnb'
    /* nestly_v897: a bar sells what a cafe sells. v275 already treats it as F&B-plus on the
       client; without this branch every drink in a bar's catalogue is cross_pack and no
       beverage ever maps itself. */
    when 'bar' then 'fnb'
    when 'salon' then 'hair_salon'
    when 'facial' then 'beauty_wellness'
    when 'massage' then 'beauty_wellness'
    /* fitness / retail / other stay generic on purpose — see this migration's header. */
    else 'generic' end;
$$;

-- =============================================================================================
-- 2. The six words a bar menu uses that a cafe menu does not.
-- =============================================================================================
insert into public.taxonomy_keywords (node_key, keyword) values
('beverages.alcohol','draught'),('beverages.alcohol','draught beer'),
('beverages.alcohol','pint'),('beverages.alcohol','lager'),
('beverages.alcohol','stout'),('beverages.alcohol','bottle beer')
on conflict (node_key, keyword) do nothing;

do $keyword_check$
declare v_bad text;
begin
  select string_agg(k.keyword, ', ') into v_bad
    from public.taxonomy_keywords k
   where k.keyword !~ '^[a-z0-9 ''-]{3,}$';
  if v_bad is not null then
    raise exception 'v897: keywords must be >=3 chars of [a-z0-9 ''-] only: %', v_bad;
  end if;
  if not exists (select 1 from public.taxonomy_keywords
                  where node_key = 'beverages.alcohol' and keyword = 'draught') then
    raise exception 'v897: the bar keywords did not land';
  end if;
end
$keyword_check$;

-- =============================================================================================
-- 3. Re-drive the v895 backfill so the bar tenants collect what they were owed.
-- =============================================================================================
-- Idempotent: confident-only, only where no mapping exists, ON CONFLICT DO NOTHING. On an
-- estate where v895 already ran, the only rows this can add are the ones the resolver and the
-- six keywords above just made reachable.
do $backfill$
declare v_n integer;
begin
  v_n := app.service_automap_backfill_v895();
  raise notice 'v897: backfill mapped % further service(s) after the bar pack landed', v_n;
end
$backfill$;

commit;
