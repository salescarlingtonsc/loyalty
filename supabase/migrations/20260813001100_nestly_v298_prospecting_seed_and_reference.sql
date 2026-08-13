-- NESTLY v298 — Prospecting reference data: SG planning areas, the sector/category
-- hierarchy, and the default lead-score weights.
--
-- All three are DATA, not code (brief §4: "Do not hard-code this taxonomy into the
-- UI. Make it data-driven through Supabase so we can add categories later without
-- changing code."). The console reads every one of these through the taxonomy RPC,
-- so adding a category or retuning a score weight is an INSERT, not a deploy.
--
-- Planning areas carry a centroid so the map can jump to an area and so an area
-- filter can be expressed as a radius when a user wants "near Hougang" rather than
-- "administratively inside Hougang".

begin;

create table if not exists public.sme_planning_areas (
  name text primary key,
  region text not null,
  latitude double precision not null,
  longitude double precision not null,
  sort_order smallint not null default 100
);
alter table public.sme_planning_areas enable row level security;
revoke all on table public.sme_planning_areas from public, anon, authenticated;

insert into public.sme_planning_areas(name, region, latitude, longitude, sort_order) values
 ('Ang Mo Kio','North-East',1.3691,103.8454,10),
 ('Bedok','East',1.3236,103.9273,20),
 ('Bishan','Central',1.3526,103.8352,30),
 ('Bukit Batok','West',1.3590,103.7637,40),
 ('Bukit Merah','Central',1.2819,103.8239,50),
 ('Bukit Panjang','West',1.3774,103.7719,60),
 ('Bukit Timah','Central',1.3294,103.8021,70),
 ('Choa Chu Kang','West',1.3840,103.7470,80),
 ('Clementi','West',1.3162,103.7649,90),
 ('Downtown Core','Central',1.2830,103.8513,100),
 ('Geylang','Central',1.3201,103.8918,110),
 ('Hougang','North-East',1.3713,103.8924,120),
 ('Jurong East','West',1.3329,103.7436,130),
 ('Jurong West','West',1.3404,103.7090,140),
 ('Kallang','Central',1.3100,103.8714,150),
 ('Marine Parade','East',1.3020,103.8971,160),
 ('Novena','Central',1.3203,103.8439,170),
 ('Pasir Ris','East',1.3721,103.9474,180),
 ('Punggol','North-East',1.3984,103.9072,190),
 ('Queenstown','Central',1.2942,103.7861,200),
 ('Sembawang','North',1.4491,103.8185,210),
 ('Sengkang','North-East',1.3868,103.8914,220),
 ('Serangoon','North-East',1.3554,103.8679,230),
 ('Tampines','East',1.3496,103.9568,240),
 ('Toa Payoh','Central',1.3343,103.8563,250),
 ('Woodlands','North',1.4382,103.7890,260),
 ('Yishun','North',1.4304,103.8354,270),
 ('Orchard','Central',1.3048,103.8318,280),
 ('Rochor','Central',1.3036,103.8520,290),
 ('Outram','Central',1.2800,103.8390,300)
on conflict (name) do nothing;

-- Sector -> Industry -> Category, exactly the shape the brief asks for. The middle
-- tier is a parent category row, so the hierarchy is arbitrary-depth by construction
-- (parent_category_id is self-referential) rather than capped at three levels.
insert into public.sme_sectors(sector_key,label,sort_order) values
 ('fnb','F&B',10),('beauty','Beauty',20),('healthcare','Healthcare',30),
 ('fitness','Fitness',40),('home_services','Home Services',50),('retail','Retail',60)
on conflict (sector_key) do nothing;

with s as (select sector_key,id from public.sme_sectors)
insert into public.sme_categories(sector_id,parent_category_id,category_key,label,sort_order)
select s.id, null, v.k, v.l, v.o from s
join (values
 ('fnb','fnb_food_services','Food Services',10),
 ('beauty','beauty_personal_care','Personal Care',10),
 ('healthcare','healthcare_medical','Medical',10),
 ('fitness','fitness_training','Fitness',10),
 ('home_services','home_trades','Home Trades',10),
 ('retail','retail_general','Retail',10)
) as v(sector_key,k,l,o) on v.sector_key=s.sector_key
on conflict (category_key) do nothing;

with parent as (
  select c.id, c.category_key, c.sector_id from public.sme_categories c
   where c.parent_category_id is null
)
insert into public.sme_categories(sector_id,parent_category_id,category_key,label,sort_order)
select p.sector_id, p.id, v.k, v.l, v.o from parent p
join (values
 ('fnb_food_services','fnb_restaurant','Restaurant',10),
 ('fnb_food_services','fnb_cafe','Cafe',20),
 ('fnb_food_services','fnb_bakery','Bakery',30),
 ('fnb_food_services','fnb_hawker','Hawker',40),
 ('fnb_food_services','fnb_fast_food','Fast Food',50),
 ('fnb_food_services','fnb_bar','Bar',60),
 ('fnb_food_services','fnb_dessert','Dessert',70),
 ('beauty_personal_care','beauty_hair_salon','Hair Salon',10),
 ('beauty_personal_care','beauty_nail_salon','Nail Salon',20),
 ('beauty_personal_care','beauty_spa','Spa',30),
 ('beauty_personal_care','beauty_aesthetic','Aesthetic',40),
 ('healthcare_medical','healthcare_dental','Dental',10),
 ('healthcare_medical','healthcare_clinic','Clinic',20),
 ('healthcare_medical','healthcare_physio','Physiotherapy',30),
 ('fitness_training','fitness_gym','Gym',10),
 ('fitness_training','fitness_pilates','Pilates',20),
 ('fitness_training','fitness_yoga','Yoga',30),
 ('fitness_training','fitness_personal','Personal Training',40),
 ('home_trades','home_renovation','Renovation',10),
 ('home_trades','home_cleaning','Cleaning',20),
 ('home_trades','home_plumbing','Plumbing',30),
 ('home_trades','home_electrical','Electrical',40),
 ('retail_general','retail_fashion','Fashion',10),
 ('retail_general','retail_electronics','Electronics',20),
 ('retail_general','retail_specialty','Specialty Retail',30)
) as v(parent_key,k,l,o) on v.parent_key=p.category_key
on conflict (category_key) do nothing;

-- Default lead-score weights (sum = 100). Rows, not constants: the brief asks for a
-- configurable model and explicitly warns against claiming predictive power, so this
-- is a ranking aid whose every point is attributable to a named signal.
insert into public.sme_lead_score_weights(signal_key,label,weight) values
 ('rating_high','Rating 4.2 or higher',15),
 ('review_volume','100+ reviews',20),
 ('has_phone','Reachable by phone',15),
 ('has_website','Has a website',10),
 ('has_email','Has an email',5),
 ('operational','Currently operating',10),
 ('geocoded','Mapped location',5),
 ('not_yet_merchant','Not yet a Peekaa merchant',10),
 ('uncontacted','Not contacted yet',10)
on conflict (signal_key) do nothing;

commit;
