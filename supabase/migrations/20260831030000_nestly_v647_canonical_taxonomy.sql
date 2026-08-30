-- NESTLY v647 — Phase C, C1: the canonical service taxonomy becomes versioned schema.
-- Owner-approved taxonomy draft (D7, defaults accepted). Four packs, three levels max,
-- and EVERY node carries the business question that justifies it — enforced by NOT NULL,
-- not by review memory. Version rows are immutable once published (the v416 versioned-
-- config discipline); future changes append a new version plus carry-map rows, so a
-- version-2 read can roll up version-1 snapshots without rewriting them.
-- Node count: the trees as approved contain 48 nodes (the draft's prose said "46" — a
-- miscount in the summary line, the trees themselves are authoritative and seeded verbatim).
-- The legacy free-text services.category is untouched: still read by promotion eligibility;
-- its retirement is a flagged follow-up decision, not this migration.
begin;

create table public.taxonomy_versions (
  version_no integer primary key check (version_no >= 1),
  published_at timestamptz not null default now(),
  notes text not null
);
create table public.taxonomy_nodes (
  id uuid primary key default gen_random_uuid(),
  version_no integer not null references public.taxonomy_versions(version_no),
  pack text not null check (pack in ('beauty_wellness','hair_salon','fnb','generic')),
  level integer not null check (level in (2,3)),
  parent_key text,
  node_key text not null,
  label text not null,
  question text not null check (length(btrim(question)) > 0),
  unique (version_no, node_key),
  check ((level = 2 and parent_key is null) or (level = 3 and parent_key is not null))
);
create table public.taxonomy_node_carry (
  from_version integer not null references public.taxonomy_versions(version_no),
  from_key text not null,
  to_version integer not null references public.taxonomy_versions(version_no),
  to_key text not null,
  primary key (from_version, from_key, to_version)
);
-- Keyword hints powering mapping suggestions (reference data, curated by migration only).
create table public.taxonomy_keywords (
  node_key text not null,
  keyword text not null check (keyword = lower(btrim(keyword))),
  primary key (node_key, keyword)
);

alter table public.taxonomy_versions enable row level security;
alter table public.taxonomy_nodes enable row level security;
alter table public.taxonomy_node_carry enable row level security;
alter table public.taxonomy_keywords enable row level security;
create policy taxonomy_versions_read on public.taxonomy_versions for select to authenticated using (true);
create policy taxonomy_nodes_read on public.taxonomy_nodes for select to authenticated using (true);
create policy taxonomy_carry_read on public.taxonomy_node_carry for select to authenticated using (true);
create policy taxonomy_keywords_read on public.taxonomy_keywords for select to authenticated using (true);
revoke all on public.taxonomy_versions, public.taxonomy_nodes, public.taxonomy_node_carry, public.taxonomy_keywords from public, anon, authenticated;
grant select on public.taxonomy_versions, public.taxonomy_nodes, public.taxonomy_node_carry, public.taxonomy_keywords to authenticated;

create or replace function app.taxonomy_guard_v647()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'taxonomy content is immutable; publish a new version instead' using errcode = '42501';
end;
$$;
create trigger trg_taxonomy_versions_immutable before update or delete on public.taxonomy_versions
  for each row execute function app.taxonomy_guard_v647();
create trigger trg_taxonomy_nodes_immutable before update or delete on public.taxonomy_nodes
  for each row execute function app.taxonomy_guard_v647();

insert into public.taxonomy_versions (version_no, notes)
values (1, 'Initial owner-approved trees (D7, 2026-08-30): beauty_wellness, hair_salon, fnb, generic.');

insert into public.taxonomy_nodes (version_no, pack, level, parent_key, node_key, label, question) values
-- ------------------------- Beauty & Wellness -------------------------
(1,'beauty_wellness',2,null,'facial','Facial','Who are my facial customers, and how often do they return?'),
(1,'beauty_wellness',3,'facial','facial.hydration','Hydration facial','Do hydration-facial customers rebook on the short cycle this family is known for?'),
(1,'beauty_wellness',3,'facial','facial.anti_aging','Anti-aging facial','Do higher-ticket anti-aging customers follow a longer, higher-value cycle?'),
(1,'beauty_wellness',3,'facial','facial.clarifying_acne','Clarifying / acne facial','Do clarifying customers complete multi-visit treatment arcs?'),
(1,'beauty_wellness',3,'facial','facial.peel_exfoliation','Peel / exfoliation','Does the skin-recovery interval govern when peel customers can return?'),
(1,'beauty_wellness',3,'facial','facial.general','Facial — general','Which facial visits cannot yet be classified more precisely (honest bucket)?'),
(1,'beauty_wellness',2,null,'massage_body','Massage & body','How do walk-in-heavy massage customers differ from facial customers?'),
(1,'beauty_wellness',3,'massage_body','massage_body.full_body_massage','Full-body massage','What is the natural rhythm of my core massage regulars?'),
(1,'beauty_wellness',3,'massage_body','massage_body.foot_reflexology','Foot / reflexology','Do reflexology customers visit more often at a lower ticket?'),
(1,'beauty_wellness',3,'massage_body','massage_body.body_treatment','Body treatment','Are scrubs/wraps promotional one-offs rather than rhythmic visits?'),
(1,'beauty_wellness',2,null,'nails','Nails','Are my nail customers on the strong 2-4 week cycle this category carries?'),
(1,'beauty_wellness',3,'nails','nails.manicure','Manicure','Which manicure customers are due back this fortnight?'),
(1,'beauty_wellness',3,'nails','nails.pedicure','Pedicure','Does pedicure cadence differ from manicure for the same customer?'),
(1,'beauty_wellness',3,'nails','nails.nail_enhancement','Nail enhancement','Do extension/art customers book longer, higher-value slots?'),
(1,'beauty_wellness',2,null,'brows_lashes','Brows & lashes','Do semi-permanent brow/lash cycles predict return windows in weeks-to-months?'),
(1,'beauty_wellness',3,'brows_lashes','brows_lashes.brow_services','Brow services','When are brow customers due for their next shaping/embroidery touch-up?'),
(1,'beauty_wellness',3,'brows_lashes','brows_lashes.lash_services','Lash services','Do lash-extension refills create a reliable 2-4 week return habit?'),
(1,'beauty_wellness',2,null,'hair_removal','Hair removal','Do waxing/IPL customers follow interval-driven courses (uniform enough for one node)?'),
(1,'beauty_wellness',2,null,'wellness_other','Wellness — other','Which wellness visits (sauna, TCM, cupping) deserve their own node once volume justifies it?'),
-- ------------------------- Hair / Salon -------------------------
(1,'hair_salon',2,null,'cut_style','Cut & style','Who are my cut customers — the frequency anchor of the salon?'),
(1,'hair_salon',3,'cut_style','cut_style.haircut','Haircut','How often does each customer actually cut, and who is overdue?'),
(1,'hair_salon',3,'cut_style','cut_style.styling_blowout','Styling / blowout','Are blowouts occasion-driven (and rightly excluded from cut cadence)?'),
(1,'hair_salon',2,null,'colour','Colour','Who are my hair-colouring customers?'),
(1,'hair_salon',3,'colour','colour.full_colour','Full colour','What is the full-colour repeat cycle and its ticket size?'),
(1,'hair_salon',3,'colour','colour.highlights_balayage','Highlights / balayage','Do balayage customers return on the long 3-6 month cycle at a higher ticket?'),
(1,'hair_salon',3,'colour','colour.root_touch_up','Root touch-up','Which colour customers are inside the short 4-6 week touch-up window right now?'),
(1,'hair_salon',2,null,'chemical','Chemical services','Do perm/rebonding customers follow quarterly-plus big-ticket cycles?'),
(1,'hair_salon',2,null,'treatment_scalp','Treatment & scalp','What is the attach rate of treatments to cuts and colour?'),
(1,'hair_salon',2,null,'extensions_wigs','Extensions & wigs','Do extension customers follow an install-then-maintain purchase pattern?'),
(1,'hair_salon',2,null,'barbering','Barbering','Do men''s grooming customers hold a short fixed cadence distinct from salon economics?'),
(1,'hair_salon',3,'barbering','barbering.mens_cut','Men''s cut','Which barbering regulars are due this week?'),
(1,'hair_salon',3,'barbering','barbering.shave_beard','Shave / beard','Does beard maintenance add visit frequency on top of cuts?'),
-- ------------------------- F&B -------------------------
(1,'fnb',2,null,'food','Food','Which visits are meal visits, and at which dayparts?'),
(1,'fnb',3,'food','food.mains','Mains','Who are my meal customers and when do they come?'),
(1,'fnb',3,'food','food.sides_snacks','Sides & snacks','What attaches to a main (basket composition)?'),
(1,'fnb',3,'food','food.desserts_bakery','Desserts & bakery','Are dessert visits treat-driven with their own daypart pattern?'),
(1,'fnb',2,null,'beverages','Beverages','Who are my beverage customers?'),
(1,'fnb',3,'beverages','beverages.coffee_tea','Coffee & tea','Who is in the daily-coffee habit cohort, and who is slipping out of it?'),
(1,'fnb',3,'beverages','beverages.specialty_drinks','Specialty drinks','Do non-coffee drink customers follow a different habit curve?'),
(1,'fnb',3,'beverages','beverages.alcohol','Alcohol','Which customers drive the evening daypart (and bottle-keep adjacency)?'),
(1,'fnb',2,null,'set_experience','Sets & experiences','Are set/buffet visits occasion behaviour rather than habit?'),
(1,'fnb',2,null,'packaged_retail','Packaged retail','Do beans/bottles/merch sell on replenishment cycles rather than visits?'),
-- ------------------------- Generic (fallback) -------------------------
(1,'generic',2,null,'consultation','Consultation','Which first-visit consultations convert into ongoing customers?'),
(1,'generic',2,null,'session_service','Session / service','The default visit bucket: keeps cadence math working for any vertical from day one.'),
(1,'generic',2,null,'class_course','Class / course','Do scheduled group/course customers attend on their enrolled rhythm?'),
(1,'generic',2,null,'rental_booking','Rental / booking','How utilised are capacity products (rooms, tables, equipment)?'),
(1,'generic',2,null,'retail_product','Retail product','What share of revenue is goods rather than services?'),
(1,'generic',2,null,'unclassified','Unclassified','Which mapped-nowhere items form the visible work queue (never a silent hole)?');

do $seed_check$
declare v_count integer;
begin
  select count(*) into v_count from public.taxonomy_nodes where version_no = 1;
  if v_count <> 48 then
    raise exception 'taxonomy v1 seed expected 48 nodes, found %', v_count;
  end if;
  if exists (select 1 from public.taxonomy_nodes c
              where c.version_no = 1 and c.level = 3
                and not exists (select 1 from public.taxonomy_nodes p
                                 where p.version_no = 1 and p.level = 2 and p.node_key = c.parent_key)) then
    raise exception 'taxonomy v1 seed has an orphan level-3 node';
  end if;
end;
$seed_check$;

insert into public.taxonomy_keywords (node_key, keyword) values
('facial.hydration','hydra'),('facial.hydration','hydration'),('facial.hydration','glass skin'),('facial.hydration','moistur'),
('facial.anti_aging','anti-aging'),('facial.anti_aging','anti aging'),('facial.anti_aging','lift'),('facial.anti_aging','collagen'),('facial.anti_aging','firming'),
('facial.clarifying_acne','acne'),('facial.clarifying_acne','clarify'),('facial.clarifying_acne','purify'),('facial.clarifying_acne','extraction'),
('facial.peel_exfoliation','peel'),('facial.peel_exfoliation','exfoliat'),('facial.peel_exfoliation','microderm'),
('facial.general','facial'),
('massage_body.full_body_massage','massage'),('massage_body.full_body_massage','aromather'),('massage_body.full_body_massage','deep tissue'),
('massage_body.foot_reflexology','foot'),('massage_body.foot_reflexology','reflexolog'),
('massage_body.body_treatment','scrub'),('massage_body.body_treatment','wrap'),('massage_body.body_treatment','slimming'),('massage_body.body_treatment','contour'),
('nails.manicure','manicure'),('nails.manicure','mani'),
('nails.pedicure','pedicure'),('nails.pedicure','pedi'),
('nails.nail_enhancement','gel ext'),('nails.nail_enhancement','acrylic'),('nails.nail_enhancement','nail art'),('nails.nail_enhancement','extension'),
('brows_lashes.brow_services','brow'),('brows_lashes.brow_services','eyebrow'),('brows_lashes.brow_services','embroider'),('brows_lashes.brow_services','microblad'),
('brows_lashes.lash_services','lash'),('brows_lashes.lash_services','eyelash'),
('hair_removal','wax'),('hair_removal','ipl'),('hair_removal','hair removal'),('hair_removal','threading'),
('wellness_other','sauna'),('wellness_other','cupping'),('wellness_other','gua sha'),('wellness_other','tcm'),
('cut_style.haircut','haircut'),('cut_style.haircut','hair cut'),('cut_style.haircut','trim'),
('cut_style.styling_blowout','blow'),('cut_style.styling_blowout','styling'),('cut_style.styling_blowout','updo'),
('colour.full_colour','colour'),('colour.full_colour','color'),('colour.full_colour','dye'),
('colour.highlights_balayage','balayage'),('colour.highlights_balayage','highlight'),('colour.highlights_balayage','ombre'),
('colour.root_touch_up','root'),('colour.root_touch_up','touch up'),('colour.root_touch_up','touch-up'),
('chemical','perm'),('chemical','rebond'),('chemical','straighten'),('chemical','keratin'),
('treatment_scalp','treatment'),('treatment_scalp','scalp'),('treatment_scalp','mask'),
('extensions_wigs','wig'),('extensions_wigs','hair extension'),
('barbering.mens_cut','barber'),('barbering.mens_cut','mens cut'),('barbering.shave_beard','shave'),('barbering.shave_beard','beard'),
('food.mains','rice'),('food.mains','noodle'),('food.mains','pasta'),('food.mains','burger'),('food.mains','mains'),
('food.sides_snacks','side'),('food.sides_snacks','snack'),('food.sides_snacks','fries'),
('food.desserts_bakery','cake'),('food.desserts_bakery','dessert'),('food.desserts_bakery','pastry'),('food.desserts_bakery','waffle'),
('beverages.coffee_tea','coffee'),('beverages.coffee_tea','kopi'),('beverages.coffee_tea','latte'),('beverages.coffee_tea','tea'),('beverages.coffee_tea','espresso'),
('beverages.specialty_drinks','smoothie'),('beverages.specialty_drinks','juice'),('beverages.specialty_drinks','milkshake'),
('beverages.alcohol','beer'),('beverages.alcohol','wine'),('beverages.alcohol','whisky'),('beverages.alcohol','cocktail'),('beverages.alcohol','sake'),
('set_experience','set meal'),('set_experience','buffet'),('set_experience','omakase'),
('packaged_retail','beans'),('packaged_retail','bottle'),('packaged_retail','merch'),
('consultation','consult'),('class_course','class'),('class_course','course'),('rental_booking','rental'),('rental_booking','room');

commit;
