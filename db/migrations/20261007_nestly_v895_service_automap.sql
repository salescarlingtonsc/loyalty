-- NESTLY v895 — services map themselves, and a wrong guess is never applied silently.
--
-- Owner, 2026-10-07: "Can services be auto-mapped instead of me finding them myself?"
-- Three things, in the order they matter:
--   1. a MUCH wider keyword list (v647 seeded 112 rows over 36 nodes; every level-2 and
--      level-3 node in all four packs now carries Singapore-relevant service names),
--   2. auto-map ON SERVICE CREATION — a DB trigger, because services are inserted straight
--      from the browser (`sb.from('services').insert`), by CSV import and by other writers,
--      so a UI-side call would cover one of the three,
--   3. accept-all in one tap (public.accept_service_mapping_suggestions_v1).
--
-- WHY THIS IS CONSERVATIVE BY CONSTRUCTION. A wrong automatic mapping silently corrupts
-- "What you sell" for a whole tenant and nobody is told, so the only acceptable failure mode
-- here is "not mapped", never "mapped wrongly". Four rules enforce that:
--   · WORD-START matching, not substring. v648's suggester was `position(keyword in text) > 0`,
--     so "spa" hit "spaghetti" mid-word and "manicure" hit "germanicure". Every match begins at
--     a word boundary: (^|[^a-z0-9]) + the escaped keyword, with any suffix allowed after it
--     (so "facial" still matches "facials", and v647's stems — hydra, exfoliat, reflexolog —
--     keep working). "spaghetti" still WORD-starts with "spa"; rule 2 is what saves it.
--   · THE PACK RULE. Matches in the business's own pack (app.business_pack_v648) outrank
--     generic, and generic outranks every other pack. An F&B "Spaghetti bolognese" therefore
--     resolves on its own pack's "spaghetti" rather than beauty's "spa". A winner from a
--     FOREIGN pack is returned as a suggestion but is never `confident` (reason 'cross_pack'),
--     so it is shown to the owner and never auto-applied.
--   · THE AMBIGUITY RULE. If another keyword of exactly the same length matches and points
--     outside the winner's level-2 family, the answer is 'ambiguous' — suggested, not applied.
--   · NEVER OVERWRITE. The trigger, accept-all and the backfill all insert only where no
--     service_canonical_map row exists, and all three use ON CONFLICT DO NOTHING on top of
--     that. An owner's choice, a console correction and an earlier automatic mapping are all
--     immovable by this migration's code paths. Re-mapping stays with the existing RPCs.
--
-- Only `confident` is ever applied automatically. Everything else lands on the mapping board
-- as a visible suggestion with the reason it was not taken.
--
-- CATEGORIES STAY FROZEN. taxonomy_versions/taxonomy_nodes keep v647's immutability triggers
-- and are not touched. public.taxonomy_keywords is reference data explicitly left unguarded by
-- v647 ("curated by migration only") and is the only taxonomy table this migration writes.
--
-- TWO v647 KEYWORDS ARE CORRECTED, not merely added to:
--   · ('hair_removal','threading') is moved to ('brows_lashes','threading'). Threading is a
--     brow service in Singapore salon listings far more often than a hair-removal one, and
--     leaving it on both would make every "Threading" service permanently 'ambiguous' — the
--     owner ruling for a genuinely two-sided keyword is the level-2 node that owns the common
--     case, not both.
--   · ('treatment_scalp','treatment') is deleted. Bare "treatment" is claimed by facial, body
--     and hair alike; because the pack rule ranks before keyword length, a hair salon's
--     "Facial treatment" resolved to treatment_scalp on a 9-character generic word. It is
--     replaced by 'hair treatment' and 'scalp treatment', which say which.
--
-- ONE KNOCK-ON FIX (public.business_manage_catalogue_item_v660). v686 counts a
-- service_canonical_map row as "this service is used", so it retires rather than deletes.
-- With auto-mapping that would silently make EVERY newly created service undeletable. An
-- automatic classification is not usage: the reference count now ignores the two automatic
-- methods, and the hard-delete path removes an automatic mapping so nothing is stranded. An
-- owner_chosen / console_corrected / accepted_suggestions mapping still counts, exactly as
-- v686 intended, because those are human decisions about the service.
--
-- ONE ACCEPTANCE FIXTURE REPAIRED. db/tests/v695_*_service_cadence*.sql inserted five services
-- and then inserted three mappings by hand, with two services "deliberately left unmapped".
-- Creation-time mapping turns that premise into a duplicate-key error and an unwanted mapping,
-- so the fixture now states the owner's three mappings with ON CONFLICT DO UPDATE and clears the
-- two it wants unmapped. The mappings it asserts are unchanged. docs/qa/CI-CORPUS-FIXTURE-GUIDE.md
-- records the new rule so the next fixture author does not rediscover it.
--
-- Rollback suite: db/tests/v895_corpus_service_automap.sql (also db/tests/executed/).
begin;

-- =============================================================================================
-- 1. Method vocabulary: three automatic provenances alongside v648's three human ones.
-- =============================================================================================
do $method_check$
declare v_name text;
begin
  select c.conname into v_name
    from pg_catalog.pg_constraint c
   where c.conrelid = 'public.service_canonical_map'::regclass
     and c.contype = 'c'
     and pg_catalog.pg_get_constraintdef(c.oid) ilike '%method%';
  if v_name is not null then
    execute format('alter table public.service_canonical_map drop constraint %I', v_name);
  end if;
end
$method_check$;

alter table public.service_canonical_map
  add constraint service_canonical_map_method_check
  check (method in ('suggested_confirmed','owner_chosen','console_corrected',
                    'auto_keyword','accepted_suggestions','auto_keyword_backfill'));

-- =============================================================================================
-- 2. Keyword corrections + the wide curated list.
-- =============================================================================================
delete from public.taxonomy_keywords where node_key = 'hair_removal'    and keyword = 'threading';
delete from public.taxonomy_keywords where node_key = 'treatment_scalp' and keyword = 'treatment';

insert into public.taxonomy_keywords (node_key, keyword) values
-- ------------------------------- beauty_wellness -------------------------------
('facial','facial'),('facial','face treatment'),('facial','skin treatment'),('facial','face mask'),
('facial','hydrafacial'),('facial','oxygen facial'),('facial','led facial'),
('facial','microdermabrasion'),('facial','extraction'),
('facial.general','general facial'),('facial.general','basic facial'),('facial.general','classic facial'),
('facial.general','signature facial'),('facial.general','express facial'),
('facial.hydration','hydrating'),('facial.hydration','moisturising'),('facial.hydration','moisturizing'),
('facial.hydration','hydrafacial'),('facial.hydration','aqua facial'),('facial.hydration','water facial'),
('facial.anti_aging','antiaging'),('facial.anti_aging','anti-ageing'),('facial.anti_aging','anti ageing'),
('facial.anti_aging','lifting'),('facial.anti_aging','radio frequency'),('facial.anti_aging','radiofrequency'),
('facial.anti_aging','rejuven'),
('facial.clarifying_acne','clarifying'),('facial.clarifying_acne','purifying'),
('facial.clarifying_acne','deep cleansing'),('facial.clarifying_acne','anti-acne'),
('facial.clarifying_acne','blemish'),('facial.clarifying_acne','pimple'),('facial.clarifying_acne','oily skin'),
('facial.peel_exfoliation','exfoliation'),('facial.peel_exfoliation','exfoliating'),
('facial.peel_exfoliation','chemical peel'),('facial.peel_exfoliation','microdermabrasion'),
('facial.peel_exfoliation','resurfacing'),('facial.peel_exfoliation','carbon peel'),
('massage_body','spa'),('massage_body','massage'),('massage_body','body massage'),
('massage_body','aromatherapy'),('massage_body','hot stone'),('massage_body','lymphatic'),
('massage_body','tui na'),('massage_body','thai massage'),('massage_body','shiatsu'),
('massage_body.full_body_massage','full body massage'),('massage_body.full_body_massage','full body'),
('massage_body.full_body_massage','swedish'),('massage_body.full_body_massage','back massage'),
('massage_body.full_body_massage','shoulder massage'),('massage_body.full_body_massage','relaxing massage'),
('massage_body.full_body_massage','neck and shoulder'),
('massage_body.foot_reflexology','foot reflexology'),('massage_body.foot_reflexology','foot massage'),
('massage_body.foot_reflexology','reflexology'),('massage_body.foot_reflexology','leg massage'),
('massage_body.foot_reflexology','foot spa'),('massage_body.foot_reflexology','sole massage'),
('massage_body.body_treatment','body scrub'),('massage_body.body_treatment','body wrap'),
('massage_body.body_treatment','body treatment'),('massage_body.body_treatment','body polish'),
('massage_body.body_treatment','salt scrub'),('massage_body.body_treatment','seaweed wrap'),
('nails','nail'),('nails','nails'),('nails','manicure'),('nails','pedicure'),('nails','gel'),
('nails','gel polish'),('nails','gelish'),('nails','nail salon'),('nails','nail care'),
('nails.manicure','gel manicure'),('nails.manicure','classic manicure'),('nails.manicure','french manicure'),
('nails.manicure','spa manicure'),('nails.manicure','hand spa'),('nails.manicure','cuticle'),
('nails.pedicure','gel pedicure'),('nails.pedicure','classic pedicure'),('nails.pedicure','french pedicure'),
('nails.pedicure','spa pedicure'),('nails.pedicure','callus'),('nails.pedicure','toe nail'),
('nails.nail_enhancement','nail extension'),('nails.nail_enhancement','gel extension'),
('nails.nail_enhancement','acrylic nail'),('nails.nail_enhancement','nail enhancement'),
('nails.nail_enhancement','builder gel'),('nails.nail_enhancement','poly gel'),
('nails.nail_enhancement','nail sculpt'),
('brows_lashes','brow'),('brows_lashes','lash'),('brows_lashes','eyebrow'),('brows_lashes','eyelash'),
('brows_lashes','threading'),('brows_lashes','tinting'),('brows_lashes','brow and lash'),
('brows_lashes.brow_services','brow lamination'),('brows_lashes.brow_services','brow shaping'),
('brows_lashes.brow_services','brow tint'),('brows_lashes.brow_services','brow embroidery'),
('brows_lashes.brow_services','microblading'),('brows_lashes.brow_services','brow wax'),
('brows_lashes.brow_services','eyebrow threading'),
('brows_lashes.lash_services','lash lift'),('brows_lashes.lash_services','lash extension'),
('brows_lashes.lash_services','eyelash extension'),('brows_lashes.lash_services','lash perm'),
('brows_lashes.lash_services','lash tint'),('brows_lashes.lash_services','lash refill'),
('brows_lashes.lash_services','keratin lash'),
('hair_removal','waxing'),('hair_removal','shr'),('hair_removal','laser hair removal'),
('hair_removal','brazilian'),('hair_removal','underarm wax'),('hair_removal','leg wax'),
('hair_removal','full body wax'),('hair_removal','bikini wax'),('hair_removal','depilat'),
('wellness_other','steam'),('wellness_other','float'),('wellness_other','yoga'),('wellness_other','pilates'),
('wellness_other','meditation'),('wellness_other','acupuncture'),('wellness_other','ear candling'),
('wellness_other','detox'),('wellness_other','moxibustion'),('wellness_other','wellness'),
-- ------------------------------- hair_salon -------------------------------
('cut_style','cut'),('cut_style','wash and blow'),('cut_style','cut and style'),('cut_style','wash and cut'),
('cut_style.haircut','ladies cut'),('cut_style.haircut','kids cut'),('cut_style.haircut','children cut'),
('cut_style.haircut','hair trim'),('cut_style.haircut','fringe trim'),('cut_style.haircut','cut only'),
('cut_style.styling_blowout','blowout'),('cut_style.styling_blowout','blow dry'),
('cut_style.styling_blowout','blow-dry'),('cut_style.styling_blowout','hair styling'),
('cut_style.styling_blowout','bridal hair'),('cut_style.styling_blowout','hair set'),
('colour','colour'),('colour','color'),('colour','bleach'),('colour','toner'),
('colour','hair tint'),('colour','colour correction'),
('colour.full_colour','hair colour'),('colour.full_colour','hair color'),('colour.full_colour','hair dye'),
('colour.full_colour','full colour'),('colour.full_colour','full color'),
('colour.full_colour','global colour'),('colour.full_colour','single process'),
('colour.highlights_balayage','highlights'),('colour.highlights_balayage','babylights'),
('colour.highlights_balayage','foils'),('colour.highlights_balayage','airtouch'),
('colour.highlights_balayage','partial highlight'),('colour.highlights_balayage','full highlight'),
('colour.root_touch_up','root touch up'),('colour.root_touch_up','root touch-up'),
('colour.root_touch_up','root coverage'),('colour.root_touch_up','regrowth'),
('colour.root_touch_up','root colour'),('colour.root_touch_up','grey coverage'),
('chemical','rebonding'),('chemical','digital perm'),('chemical','hair straightening'),
('chemical','relaxer'),('chemical','keratin treatment'),('chemical','soft perm'),
('chemical','volume rebonding'),('chemical','cold perm'),
('treatment_scalp','scalp treatment'),('treatment_scalp','hair treatment'),('treatment_scalp','scalp care'),
('treatment_scalp','hair spa'),('treatment_scalp','hair mask'),('treatment_scalp','anti-dandruff'),
('treatment_scalp','dandruff'),('treatment_scalp','scalp detox'),
('extensions_wigs','wigs'),('extensions_wigs','hair extensions'),('extensions_wigs','weave'),
('extensions_wigs','hairpiece'),('extensions_wigs','hair piece'),('extensions_wigs','clip in'),
('extensions_wigs','tape in'),('extensions_wigs','keratin bond'),
('barbering','barber'),('barbering','barbershop'),('barbering','fade'),
('barbering','gents grooming'),('barbering','mens grooming'),
('barbering.mens_cut','men''s cut'),('barbering.mens_cut','gents cut'),('barbering.mens_cut','skin fade'),
('barbering.mens_cut','crew cut'),('barbering.mens_cut','buzz cut'),('barbering.mens_cut','boys cut'),
('barbering.mens_cut','taper fade'),
('barbering.shave_beard','beard trim'),('barbering.shave_beard','hot towel shave'),
('barbering.shave_beard','beard shaping'),('barbering.shave_beard','moustache'),
('barbering.shave_beard','razor shave'),('barbering.shave_beard','beard grooming'),
-- ------------------------------- fnb -------------------------------
('food','food'),('food','meal'),('food','lunch'),('food','dinner'),('food','breakfast'),('food','brunch'),
('food.mains','spaghetti'),('food.mains','laksa'),('food.mains','prata'),('food.mains','chicken rice'),
('food.mains','fried rice'),('food.mains','curry'),('food.mains','sandwich'),('food.mains','bee hoon'),
('food.mains','kway teow'),('food.mains','nasi lemak'),('food.mains','mee goreng'),('food.mains','pizza'),
('food.mains','main course'),
('food.sides_snacks','sides'),('food.sides_snacks','snacks'),('food.sides_snacks','french fries'),
('food.sides_snacks','nuggets'),('food.sides_snacks','spring roll'),('food.sides_snacks','chips'),
('food.sides_snacks','appetiser'),('food.sides_snacks','appetizer'),
('food.desserts_bakery','bread'),('food.desserts_bakery','croissant'),('food.desserts_bakery','cookie'),
('food.desserts_bakery','gelato'),('food.desserts_bakery','ice cream'),('food.desserts_bakery','tart'),
('food.desserts_bakery','muffin'),('food.desserts_bakery','bakery'),('food.desserts_bakery','desserts'),
('food.desserts_bakery','brownie'),('food.desserts_bakery','kaya toast'),
('beverages','drink'),('beverages','drinks'),('beverages','beverage'),('beverages','beverages'),
('beverages','soft drink'),
('beverages.coffee_tea','teh'),('beverages.coffee_tea','teh tarik'),('beverages.coffee_tea','cappuccino'),
('beverages.coffee_tea','americano'),('beverages.coffee_tea','mocha'),('beverages.coffee_tea','flat white'),
('beverages.coffee_tea','matcha'),('beverages.coffee_tea','green tea'),('beverages.coffee_tea','kopi o'),
('beverages.coffee_tea','long black'),('beverages.coffee_tea','cold brew'),
('beverages.specialty_drinks','bubble tea'),('beverages.specialty_drinks','boba'),
('beverages.specialty_drinks','milk tea'),('beverages.specialty_drinks','soda'),
('beverages.specialty_drinks','lemonade'),('beverages.specialty_drinks','frappe'),
('beverages.specialty_drinks','yakult'),('beverages.specialty_drinks','fruit tea'),
('beverages.specialty_drinks','root beer'),
('beverages.alcohol','whiskey'),('beverages.alcohol','vodka'),('beverages.alcohol','tequila'),
('beverages.alcohol','soju'),('beverages.alcohol','highball'),('beverages.alcohol','draft beer'),
('beverages.alcohol','house wine'),('beverages.alcohol','cocktails'),('beverages.alcohol','shochu'),
('set_experience','set lunch'),('set_experience','set dinner'),('set_experience','tasting menu'),
('set_experience','course menu'),('set_experience','high tea'),('set_experience','set menu'),
('packaged_retail','packaged'),('packaged_retail','bottled'),('packaged_retail','retail pack'),
('packaged_retail','take home'),('packaged_retail','tumbler'),('packaged_retail','gift set'),
('packaged_retail','coffee beans'),('packaged_retail','tea leaves'),('packaged_retail','canned'),
-- ------------------------------- generic -------------------------------
('consultation','consultation'),('consultation','assessment'),('consultation','diagnosis'),
('consultation','first visit'),('consultation','evaluation'),('consultation','advisory'),
('session_service','standard session'),('session_service','single session'),
('session_service','general service'),('session_service','one-off service'),
('session_service','walk-in service'),('session_service','drop-in session'),
('class_course','workshop'),('class_course','lesson'),('class_course','training'),
('class_course','masterclass'),('class_course','bootcamp'),('class_course','tuition'),
('class_course','classes'),
('rental_booking','booking'),('rental_booking','room hire'),('rental_booking','hire'),
('rental_booking','venue'),('rental_booking','rent'),('rental_booking','equipment rental'),
('rental_booking','room rental'),('rental_booking','function room'),
('retail_product','retail product'),('retail_product','retail item'),('retail_product','product sale'),
('retail_product','merchandise'),('retail_product','product purchase'),('retail_product','retail sale'),
('unclassified','unclassified'),('unclassified','uncategorised'),('unclassified','uncategorized'),
('unclassified','miscellaneous'),('unclassified','others'),('unclassified','misc')
on conflict (node_key, keyword) do nothing;

-- Coverage and shape are asserted here rather than trusted: a future edit that drops a node
-- below the owner-agreed floor, or introduces a keyword the matcher cannot escape safely,
-- fails the migration instead of quietly degrading suggestions.
do $keyword_check$
declare v_bad text; v_thin text; v_total integer; v_nodes integer;
begin
  select string_agg(k.keyword, ', ') into v_bad
    from public.taxonomy_keywords k
   where k.keyword !~ '^[a-z0-9 ''-]{3,}$';
  if v_bad is not null then
    raise exception 'v895: keywords must be >=3 chars of [a-z0-9 ''-] only: %', v_bad;
  end if;

  select string_agg(format('%s(%s/%s)', n.node_key, c.n, case n.level when 3 then 6 else 4 end), ', ')
    into v_thin
    from public.taxonomy_nodes n
    join lateral (select count(*) as n from public.taxonomy_keywords k where k.node_key = n.node_key) c on true
   where n.version_no = 1
     and c.n < case n.level when 3 then 6 else 4 end;
  if v_thin is not null then
    raise exception 'v895: these nodes are below the keyword floor: %', v_thin;
  end if;

  select count(*), count(distinct k.node_key) into v_total, v_nodes from public.taxonomy_keywords k;
  raise notice 'v895: taxonomy_keywords now holds % rows over % nodes', v_total, v_nodes;
  if not exists (select 1 from public.taxonomy_keywords where node_key='brows_lashes' and keyword='threading')
     or exists (select 1 from public.taxonomy_keywords where node_key='hair_removal' and keyword='threading') then
    raise exception 'v895: the threading correction did not take';
  end if;
  if exists (select 1 from public.taxonomy_keywords where node_key='treatment_scalp' and keyword='treatment') then
    raise exception 'v895: bare "treatment" was not retired from treatment_scalp';
  end if;
end
$keyword_check$;

-- =============================================================================================
-- 3. The matcher.
-- =============================================================================================

-- One authority for "where may this keyword begin". Escaping every non [a-z0-9 ] character is
-- deliberate belt-and-braces: the column check keeps keywords lowercase and the check above
-- keeps them to [a-z0-9 '-], so the only characters ever escaped are ASCII punctuation, for
-- which ARE defines \x as the literal x.
create or replace function app.taxonomy_keyword_pattern_v895(p_keyword text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select '(^|[^a-z0-9])' || regexp_replace(lower(btrim(coalesce(p_keyword, ''))), '([^a-z0-9 ])', '\\\1', 'g');
$$;
revoke all on function app.taxonomy_keyword_pattern_v895(text) from public, anon, authenticated;
grant execute on function app.taxonomy_keyword_pattern_v895(text) to service_role;

-- The core: text in, ranked verdict out. The trigger calls this with NEW's own text rather
-- than re-reading the row, so creation-time mapping never depends on AFTER-trigger snapshot
-- visibility; app.suggest_canonical_node_v2 is the same function with a service lookup in
-- front of it. One matcher, two entry points, no second opinion.
create or replace function app.suggest_canonical_node_text_v895(p_business uuid, p_text text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_pack text := app.business_pack_v648(p_business);
  v_text text := lower(coalesce(p_text, ''));
  v_win record;
  v_rivals integer := 0;
  v_reason text;
begin
  select k.node_key                          as node_key,
         k.keyword                           as keyword,
         n.pack                              as pack,
         n.label                             as label,
         coalesce(n.parent_key, n.node_key)  as family,
         length(k.keyword)                   as klen
    into v_win
    from public.taxonomy_keywords k
    join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = k.node_key
   where v_text ~ app.taxonomy_keyword_pattern_v895(k.keyword)
   order by (case when n.pack = v_pack then 2 when n.pack = 'generic' then 1 else 0 end) desc,
            length(k.keyword) desc,
            n.level desc,
            k.node_key
   limit 1;

  if not found then
    return jsonb_build_object('node_key', null, 'label', null, 'keyword', null,
                              'pack', null, 'confident', false, 'reason', 'no_match');
  end if;

  if v_win.pack <> v_pack and v_win.pack <> 'generic' then
    v_reason := 'cross_pack';
  else
    select count(*) into v_rivals
      from public.taxonomy_keywords k
      join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = k.node_key
     where length(k.keyword) = v_win.klen
       and coalesce(n.parent_key, n.node_key) <> v_win.family
       and v_text ~ app.taxonomy_keyword_pattern_v895(k.keyword);
    v_reason := case when v_rivals > 0 then 'ambiguous' else 'own_pack_unique' end;
  end if;

  return jsonb_build_object(
    'node_key',  v_win.node_key,
    'label',     v_win.label,
    'keyword',   v_win.keyword,
    'pack',      v_win.pack,
    'confident', v_reason = 'own_pack_unique',
    'reason',    v_reason);
end;
$$;
revoke all on function app.suggest_canonical_node_text_v895(uuid,text) from public, anon, authenticated;
grant execute on function app.suggest_canonical_node_text_v895(uuid,text) to service_role;

create or replace function app.suggest_canonical_node_v2(p_business uuid, p_service uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_text text;
begin
  select lower(coalesce(s.name, '') || ' ' || coalesce(s.category, '')) into v_text
    from public.services s
   where s.id = p_service and s.business_id = p_business;
  if not found then return null; end if;
  return app.suggest_canonical_node_text_v895(p_business, v_text);
end;
$$;
revoke all on function app.suggest_canonical_node_v2(uuid,uuid) from public, anon, authenticated;
grant execute on function app.suggest_canonical_node_v2(uuid,uuid) to service_role;

-- v648's v1 is re-emitted as a thin projection of v2 so the board, this migration and any
-- future caller read ONE answer. This changes v1's behaviour: substring matching becomes
-- word-start matching, and the pack preference gains its generic middle tier. Anything v1
-- used to suggest from a mid-word hit ("spa" inside "spaghetti") it no longer suggests.
create or replace function app.suggest_canonical_node_v1(p_business uuid, p_service uuid)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.suggest_canonical_node_v2(p_business, p_service) ->> 'node_key';
$$;
revoke all on function app.suggest_canonical_node_v1(uuid,uuid) from public, anon, authenticated;
grant execute on function app.suggest_canonical_node_v1(uuid,uuid) to service_role;

-- =============================================================================================
-- 4. Auto-map at creation. AFTER INSERT only.
-- =============================================================================================
-- Never on UPDATE: renaming a service must not silently re-map what the owner chose, and a
-- rename is exactly when a business corrects wording the owner already classified by hand.
-- Never raises: analytics metadata may not block a service insert, so every failure path
-- swallows and returns NEW. SECURITY DEFINER because service_canonical_map carries no INSERT
-- policy — the mapping is written by the product's own routes, never by a client.
create or replace function app.service_automap_v895()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_sugg jsonb;
begin
  begin
    if exists (select 1 from public.service_canonical_map m
                where m.business_id = new.business_id and m.service_id = new.id) then
      return new;
    end if;
    v_sugg := app.suggest_canonical_node_text_v895(
                new.business_id,
                lower(coalesce(new.name, '') || ' ' || coalesce(new.category, '')));
    if v_sugg is null or not coalesce((v_sugg ->> 'confident')::boolean, false) then
      return new;
    end if;
    insert into public.service_canonical_map
      (business_id, service_id, node_key, version_no, method, mapped_by, mapped_at)
    values (new.business_id, new.id, v_sugg ->> 'node_key', 1, 'auto_keyword', auth.uid(), now())
    on conflict (business_id, service_id) do nothing;
  exception when others then
    return new;
  end;
  return new;
end;
$$;
revoke all on function app.service_automap_v895() from public, anon, authenticated;
grant execute on function app.service_automap_v895() to service_role;

drop trigger if exists trg_service_automap_v895 on public.services;
create trigger trg_service_automap_v895
  after insert on public.services
  for each row execute function app.service_automap_v895();

-- =============================================================================================
-- 5. Accept-all in one tap.
-- =============================================================================================
create or replace function public.accept_service_mapping_suggestions_v1(
  p_business uuid, p_only_confident boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_mapped integer := 0;
  v_no_sugg integer := 0;
  v_not_conf integer := 0;
  v_written integer;
  v_rows jsonb := '[]'::jsonb;
  v_sugg jsonb;
  r record;
begin
  -- The same gate as set_service_canonical_node_v1 (nestly_v648), verbatim: accepting every
  -- suggestion at once is the same authority as accepting one, exercised in bulk.
  if auth.uid() is null
     or not app.is_salon_member(p_business)
     or not app.can_module_write(p_business, 'services') then
    raise exception 'services write access is required' using errcode = '42501';
  end if;

  for r in
    select s.id, s.name
      from public.services s
     where s.business_id = p_business
       and not exists (select 1 from public.service_canonical_map m
                        where m.business_id = s.business_id and m.service_id = s.id)
     order by s.name, s.id
  loop
    v_sugg := app.suggest_canonical_node_v2(p_business, r.id);
    if v_sugg is null or v_sugg ->> 'node_key' is null then
      v_no_sugg := v_no_sugg + 1;
      continue;
    end if;
    if p_only_confident and not coalesce((v_sugg ->> 'confident')::boolean, false) then
      v_not_conf := v_not_conf + 1;
      continue;
    end if;
    insert into public.service_canonical_map
      (business_id, service_id, node_key, version_no, method, mapped_by)
    values (p_business, r.id, v_sugg ->> 'node_key', 1, 'accepted_suggestions', auth.uid())
    on conflict (business_id, service_id) do nothing;
    get diagnostics v_written = row_count;
    if v_written = 1 then
      v_mapped := v_mapped + 1;
      v_rows := v_rows || jsonb_build_object(
        'service_id', r.id, 'name', r.name,
        'node_key', v_sugg ->> 'node_key', 'label', v_sugg ->> 'label',
        'confident', coalesce((v_sugg ->> 'confident')::boolean, false));
    end if;
  end loop;

  return jsonb_build_object(
    'mapped', v_mapped,
    'skipped_no_suggestion', v_no_sugg,
    'skipped_not_confident', v_not_conf,
    'rows', v_rows);
end;
$$;
revoke all on function public.accept_service_mapping_suggestions_v1(uuid,boolean) from public, anon;
grant execute on function public.accept_service_mapping_suggestions_v1(uuid,boolean) to authenticated, service_role;

-- =============================================================================================
-- 6. Backfill — a named function, called once here, re-drivable by the acceptance suite.
-- =============================================================================================
-- CONFIDENT ONLY, estate-wide, mapped_by null (no human made this choice), and only where no
-- mapping exists. Returns how many rows it wrote, so a second call returning 0 is the proof
-- that it is idempotent rather than an assertion that it is.
create or replace function app.service_automap_backfill_v895()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_total integer := 0; v_written integer; v_sugg jsonb; r record;
begin
  for r in
    select s.id, s.business_id
      from public.services s
     where not exists (select 1 from public.service_canonical_map m
                        where m.business_id = s.business_id and m.service_id = s.id)
     order by s.business_id, s.id
  loop
    v_sugg := app.suggest_canonical_node_v2(r.business_id, r.id);
    if v_sugg is null or not coalesce((v_sugg ->> 'confident')::boolean, false) then
      continue;
    end if;
    insert into public.service_canonical_map
      (business_id, service_id, node_key, version_no, method, mapped_by)
    values (r.business_id, r.id, v_sugg ->> 'node_key', 1, 'auto_keyword_backfill', null)
    on conflict (business_id, service_id) do nothing;
    get diagnostics v_written = row_count;
    v_total := v_total + v_written;
  end loop;
  return v_total;
end;
$$;
revoke all on function app.service_automap_backfill_v895() from public, anon, authenticated;
grant execute on function app.service_automap_backfill_v895() to service_role;

do $backfill$
declare v_n integer;
begin
  v_n := app.service_automap_backfill_v895();
  raise notice 'v895: backfill mapped % previously unmapped service(s)', v_n;
end
$backfill$;

-- =============================================================================================
-- 7. The mapping board learns why, and how many are waiting.
-- =============================================================================================
-- Additive: every key v648 returned is still returned, with the same meaning.
create or replace function public.get_service_mapping_board_v1(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_services jsonb;
  v_confident integer;
  v_possible integer;
begin
  if auth.uid() is null
     or not app.is_salon_member(p_business)
     or not app.can_module(p_business, 'services') then
    raise exception 'services access is required' using errcode = '42501';
  end if;

  with board as (
    select s.id, s.name, s.category, s.active,
           m.node_key, m.method, m.mapped_at,
           app.suggest_canonical_node_v2(p_business, s.id) as sugg
      from public.services s
      left join public.service_canonical_map m
        on m.business_id = s.business_id and m.service_id = s.id
     where s.business_id = p_business
  )
  select
    jsonb_agg(jsonb_build_object(
      'service_id', b.id, 'name', b.name, 'legacy_category', b.category,
      'active', b.active,
      'node_key', b.node_key, 'method', b.method,
      'mapped_method', b.method, 'mapped_at', b.mapped_at,
      'suggested_node_key', b.sugg ->> 'node_key',
      'suggested_confident', coalesce((b.sugg ->> 'confident')::boolean, false),
      'suggested_keyword', b.sugg ->> 'keyword',
      'suggested_reason', coalesce(b.sugg ->> 'reason', 'no_match'))
      order by b.active desc, b.name),
    count(*) filter (where b.node_key is null
                       and coalesce((b.sugg ->> 'confident')::boolean, false)),
    count(*) filter (where b.node_key is null
                       and b.sugg ->> 'node_key' is not null
                       and not coalesce((b.sugg ->> 'confident')::boolean, false))
    into v_services, v_confident, v_possible
    from board b;

  return jsonb_build_object(
    'pack', app.business_pack_v648(p_business),
    'services', coalesce(v_services, '[]'::jsonb),
    'suggestions', jsonb_build_object(
      'confident', coalesce(v_confident, 0),
      'possible', coalesce(v_possible, 0)),
    'nodes', (select jsonb_agg(jsonb_build_object(
                'node_key', n.node_key, 'pack', n.pack, 'level', n.level,
                'parent_key', n.parent_key, 'label', n.label) order by n.pack, n.level, n.node_key)
                from public.taxonomy_nodes n where n.version_no = 1));
end;
$$;
revoke all on function public.get_service_mapping_board_v1(uuid) from public, anon;
grant execute on function public.get_service_mapping_board_v1(uuid) to authenticated, service_role;

-- =============================================================================================
-- 8. Knock-on: an automatic mapping is not "this service is used".
-- =============================================================================================
-- nestly_v686 made a service_canonical_map row count towards the retire-instead-of-delete
-- reference count, because a mapping the owner made is a decision about the service and
-- service_canonical_map has no FK to clean up after a delete. With section 4 above, EVERY new
-- service acquires a mapping within the same statement that creates it, so without this change
-- a service created by mistake could never be removed again — it would silently retire, and
-- the owner would be told "used_by 1" about a row they never made.
--
-- Two edits to the v686 text, and nothing else:
--   · the service reference count ignores 'auto_keyword' and 'auto_keyword_backfill'.
--     'accepted_suggestions' still counts: tapping Accept all IS a human decision.
--   · the hard-delete path removes the automatic mapping first, so the delete strands nothing
--     (the same concern v686 raised, answered instead of avoided).
create or replace function public.business_manage_catalogue_item_v660(
  p_business uuid, p_kind text, p_item uuid, p_action text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_used integer := 0;
  v_name text;
  v_active boolean;
  v_retired timestamptz;
  v_retiring boolean := false;
begin
  if p_action <> 'delete' then
    raise exception 'unsupported catalogue action' using errcode = '22023';
  end if;
  if v_kind not in ('service','product') then
    raise exception 'catalogue item must be a service or a product' using errcode = '22023';
  end if;
  -- Each catalogue lives behind its own module, exactly as its page does.
  if not app.can_module_write(p_business, case when v_kind = 'service' then 'services' else 'inventory' end) then
    raise exception 'catalogue write access is required' using errcode = '42501';
  end if;

  if v_kind = 'service' then
    select name, active, retired_at into v_name, v_active, v_retired
      from public.services where id = p_item and business_id = p_business for update;
    if not found then raise exception 'service not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.appointment_services x where x.service_id = p_item)
    + (select count(*) from public.appointments x where x.service_id = p_item)
    + (select count(*) from public.booking_requests x where x.service_id = p_item)
    + (select count(*) from public.waitlist x where x.service_id = p_item)
    + (select count(*) from public.package_plans x where x.service_id = p_item)
    + (select count(*) from public.loyalty_reward_services x where x.service_id = p_item)
    + (select count(*) from public.bundle_items x where x.service_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.service_id = p_item)
    + (select count(*) from public.sale_items x where x.business_id = p_business and x.ref_id = p_item)
    /* nestly_v686. service_canonical_map.service_id has no FK, so a delete strands the Phase C
       mapping v636's own comment names; service_products cascades, so a delete silently takes
       the consumption recipe with it. Both make a service "used": it is retired, not removed.
       nestly_v895: except when the mapping is one this platform made by itself. An automatic
       keyword classification is metadata about a name, not a decision about a service, and
       counting it would make every newly created service permanently undeletable. */
    + (select count(*) from public.service_canonical_map x
        where x.business_id = p_business and x.service_id = p_item
          and x.method not in ('auto_keyword','auto_keyword_backfill'))
    + (select count(*) from public.service_products x where x.service_id = p_item)
      into v_used;
  else
    select name, active, retired_at into v_name, v_active, v_retired
      from public.products where id = p_item and business_id = p_business for update;
    if not found then raise exception 'product not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.sale_items x where x.product_id = p_item)
    + (select count(*) from public.sales x where x.product_id = p_item)
    + (select count(*) from public.stock_batches x where x.product_id = p_item)
    + (select count(*) from public.bar_bottles x where x.product_id = p_item)
    + (select count(*) from public.loyalty_reward_products x where x.product_id = p_item)
    + (select count(*) from public.bundle_items x where x.product_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.product_id = p_item)
    + (select count(*) from public.tier_benefits_v365 x where x.product_id = p_item)
    + (select count(*) from public.service_products x where x.product_id = p_item)
      into v_used;
  end if;

  if v_used > 0 then
    if v_retired is not null then
      raise exception 'this item is already off sale' using errcode = '22023';
    end if;
    v_retiring := true;
    if v_kind = 'service' then
      update public.services set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    else
      update public.products set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    end if;
  else
    /* nestly_v686. This is the permanent act, and for a service it is the owner's alone —
       policy services_delete_v636 says so, and SECURITY DEFINER is why the policy could not say
       it here. Retiring above stays open to anyone with services write, matching the RLS UPDATE
       policy; only destroying the row is narrowed. */
    if v_kind = 'service' and not app.is_salon_owner(p_business) then
      raise exception 'only the owner can permanently delete a service' using errcode = '42501';
    end if;
    if v_kind = 'service' then
      /* nestly_v895. The automatic mapping is the only reference this path is allowed to
         destroy, and it is destroyed explicitly so the history trigger records the removal. */
      delete from public.service_canonical_map
       where business_id = p_business and service_id = p_item
         and method in ('auto_keyword','auto_keyword_backfill');
      delete from public.services where id = p_item and business_id = p_business;
    else
      delete from public.products where id = p_item and business_id = p_business;
    end if;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(),
         v_kind || '.' || case when v_retiring then 'retire' else 'delete' end,
         case when v_kind = 'service' then 'services' else 'products' end, p_item,
         jsonb_build_object('name', v_name, 'used_by', v_used, 'retired', v_retiring));

  return json_build_object('status','ok','kind',v_kind,
    'action', case when v_retiring then 'retire' else 'delete' end,
    'item_id', p_item, 'used_by', v_used);
end
$function$;

/* The live grant, restated verbatim (production today: EXECUTE to authenticated and
   service_role, and to nobody else). */
revoke all on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) from public, anon;
grant execute on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) to authenticated, service_role;

commit;
