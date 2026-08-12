-- NESTLY v297 — Merchant Prospecting CRM + Map Intelligence: the data layer.
--
-- DESIGN DECISION THAT SHAPES EVERYTHING ELSE. The brief specifies a `businesses`
-- table with contacts / outreach / merchant_records / saved_filters / lead_scores.
-- Peekaa already has BOTH halves of that under different names, and building the
-- brief literally would have created two competing CRMs and a name collision:
--
--   * `public.businesses` is ALREADY TAKEN — it is the live multi-tenant merchant
--     table (34 columns, RLS, the conversion TARGET). A second `businesses` was
--     never an option.
--   * `sme_companies` + `sme_prospects` are ALREADY the prospect CRM, with 40+
--     supporting tables: contacts (sme_prospect_contacts), assignment
--     (sme_prospect_assignments), follow-up tasks (sme_prospect_tasks), a 19-stage
--     pipeline (sme_pipeline_stages), stage history, import batches with dedupe
--     candidates, documents, quotations, and conversion
--     (sme_prospects.converted_business_id / converted_at) — the brief's
--     `merchant_records` already exists as those columns.
--
-- So this migration EXTENDS that CRM rather than duplicating it. Every new table
-- hangs off sme_companies or sme_prospects. Nothing existing is renamed, dropped
-- or re-pointed, so every shipped CRM screen keeps working unchanged.
--
-- Brief -> Peekaa mapping (what this migration adds is only the genuine gap):
--   businesses          -> sme_companies (existing) + v297 market facts/sources
--   locations           -> sme_company_locations           (NEW: the whole geo layer)
--   sectors/categories  -> sme_sectors / sme_categories    (NEW: hierarchy, was flat text)
--   business_categories -> sme_company_categories          (NEW)
--   contacts            -> sme_prospect_contacts (existing) + whatsapp/contact_type
--   outreach_records    -> sme_outreach_records            (NEW: channel+outcome+follow-up)
--   merchant_records    -> sme_prospects.converted_* (existing)
--   saved_filters       -> sme_saved_filters               (NEW)
--   lead_scores         -> sme_lead_scores + weights       (NEW, configurable)
--
-- GEO WITHOUT POSTGIS. This project has no postgis/earthdistance extension and
-- adding one to a managed instance for a radius filter is not worth the operational
-- surface. Radius search is a btree-indexed bounding-box prefilter followed by an
-- exact haversine, which is both index-friendly and exactly correct at SG scale.
--
-- PROVIDER FIELDS ARE PHYSICALLY SEPARATE FROM CURATED FIELDS (brief §15: "do not
-- overwrite manually edited CRM fields with provider data"). Provider-owned truth
-- lives in sme_company_market_facts + sme_company_sources; a human's edits live on
-- sme_companies. A re-sync can never clobber a curated name or phone because it
-- physically does not write that table.
--
-- COST CONTROL (brief §14). sme_company_sources carries UNIQUE(source, source_id) —
-- the Google Place ID — so a re-discovery of the same place is an upsert, never a
-- second row and never a second paid Details call. sme_discovery_runs records what
-- each run cost in calls so an unrestricted "download everything" job is visibly
-- absent and any run's spend is auditable.
--
-- SECURITY. Every table here is definer-only: RLS on, and NO browser-role grant at
-- all. The only way in is the v297 SECURITY DEFINER RPCs, which re-check platform
-- role on each call. Scoping honours the standing owner rule (2026-08-10): a
-- sales_staff sees only prospects assigned to them; admin sees all; ONLY the super
-- admin assigns. No provider API key is stored in, or reachable from, the database.

begin;

-- ---------------------------------------------------------------- taxonomy
create table if not exists public.sme_sectors (
  id uuid primary key default gen_random_uuid(),
  sector_key text not null unique,
  label text not null,
  sort_order smallint not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.sme_sectors enable row level security;
revoke all on table public.sme_sectors from public, anon, authenticated;

create table if not exists public.sme_categories (
  id uuid primary key default gen_random_uuid(),
  sector_id uuid not null references public.sme_sectors(id) on delete cascade,
  parent_category_id uuid references public.sme_categories(id) on delete cascade,
  category_key text not null unique,
  label text not null,
  sort_order smallint not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.sme_categories enable row level security;
revoke all on table public.sme_categories from public, anon, authenticated;
create index if not exists sme_categories_sector_idx on public.sme_categories(sector_id, sort_order);
create index if not exists sme_categories_parent_idx on public.sme_categories(parent_category_id);

create table if not exists public.sme_company_categories (
  company_id uuid not null references public.sme_companies(id) on delete cascade,
  category_id uuid not null references public.sme_categories(id) on delete cascade,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (company_id, category_id)
);
alter table public.sme_company_categories enable row level security;
revoke all on table public.sme_company_categories from public, anon, authenticated;
create index if not exists sme_company_categories_category_idx
  on public.sme_company_categories(category_id);
-- At most one primary category per company.
create unique index if not exists sme_company_categories_one_primary
  on public.sme_company_categories(company_id) where is_primary;

-- ---------------------------------------------------------------- geography
create table if not exists public.sme_company_locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete cascade,
  country text not null default 'SG',
  planning_area text,
  district text,
  area text,
  address text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  is_primary boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sme_company_locations_lat_range
    check (latitude is null or latitude between -90 and 90),
  constraint sme_company_locations_lng_range
    check (longitude is null or longitude between -180 and 180)
);
alter table public.sme_company_locations enable row level security;
revoke all on table public.sme_company_locations from public, anon, authenticated;
create unique index if not exists sme_company_locations_one_primary
  on public.sme_company_locations(company_id) where is_primary;
-- The map's hot path: a bounding-box scan. Composite (lat,lng) serves the range
-- prefilter; the partial predicate keeps un-geocoded rows out of the index entirely.
create index if not exists sme_company_locations_geo_idx
  on public.sme_company_locations(latitude, longitude)
  where latitude is not null and longitude is not null;
create index if not exists sme_company_locations_area_idx
  on public.sme_company_locations(planning_area) where planning_area is not null;
create index if not exists sme_company_locations_postal_idx
  on public.sme_company_locations(postal_code) where postal_code is not null;
create index if not exists sme_company_locations_company_idx
  on public.sme_company_locations(company_id);

-- ---------------------------------------------------------------- provider truth
-- Provider-owned observations. Physically separate from sme_companies so a re-sync
-- can never overwrite a human's curated edit (brief §15).
create table if not exists public.sme_company_market_facts (
  company_id uuid primary key references public.sme_companies(id) on delete cascade,
  business_status text,
  rating numeric(2,1),
  review_count integer,
  price_level smallint,
  provider_phone text,
  provider_website text,
  opening_hours jsonb,
  last_synced_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint sme_company_market_facts_rating_range
    check (rating is null or rating between 0 and 5),
  constraint sme_company_market_facts_reviews_nonneg
    check (review_count is null or review_count >= 0),
  constraint sme_company_market_facts_price_range
    check (price_level is null or price_level between 0 and 4)
);
alter table public.sme_company_market_facts enable row level security;
revoke all on table public.sme_company_market_facts from public, anon, authenticated;
create index if not exists sme_company_market_facts_rating_idx
  on public.sme_company_market_facts(rating desc nulls last, review_count desc nulls last);

-- Dedup spine. UNIQUE(source, source_id) is what makes "discover Hougang cafes"
-- twice cost one row and one paid lookup instead of two.
create table if not exists public.sme_company_sources (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete cascade,
  source text not null,
  source_id text not null,
  source_url text,
  detail_fetched_at timestamptz,
  first_seen_at timestamptz not null default now(),
  last_synced_at timestamptz not null default now(),
  constraint sme_company_sources_unique unique (source, source_id)
);
alter table public.sme_company_sources enable row level security;
revoke all on table public.sme_company_sources from public, anon, authenticated;
create index if not exists sme_company_sources_company_idx
  on public.sme_company_sources(company_id);

-- ---------------------------------------------------------------- outreach
-- sme_prospect_activities is a free-text journal. Outreach needs STRUCTURE
-- (channel + outcome + follow-up) so the CRM can filter "not contacted",
-- "follow-up overdue" and "interested" in SQL rather than by reading prose.
create table if not exists public.sme_outreach_records (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete cascade,
  contact_id uuid references public.sme_prospect_contacts(id) on delete set null,
  consultant_id uuid references public.platform_consultants(id) on delete set null,
  channel text not null,
  contacted_at timestamptz not null default now(),
  outcome text not null,
  notes text,
  next_follow_up_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  constraint sme_outreach_records_channel_check
    check (channel in ('call','whatsapp','sms','email','visit','other')),
  constraint sme_outreach_records_outcome_check
    check (outcome in ('no_answer','spoke_to_owner','interested','follow_up',
                       'not_interested','wrong_number','competitor','converted','do_not_contact'))
);
alter table public.sme_outreach_records enable row level security;
revoke all on table public.sme_outreach_records from public, anon, authenticated;
create index if not exists sme_outreach_records_prospect_idx
  on public.sme_outreach_records(prospect_id, contacted_at desc);
create index if not exists sme_outreach_records_follow_up_idx
  on public.sme_outreach_records(next_follow_up_at)
  where next_follow_up_at is not null;
create index if not exists sme_outreach_records_outcome_idx
  on public.sme_outreach_records(outcome, contacted_at desc);

-- ---------------------------------------------------------------- saved filters
create table if not exists public.sme_saved_filters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  filter_config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sme_saved_filters_name_unique unique (user_id, name),
  constraint sme_saved_filters_name_length check (length(btrim(name)) between 1 and 80)
);
alter table public.sme_saved_filters enable row level security;
revoke all on table public.sme_saved_filters from public, anon, authenticated;

-- ---------------------------------------------------------------- lead scoring
-- Configurable, NOT hard-coded (brief §10). Weights are rows so the model can be
-- tuned without a migration, and the breakdown is stored so the score is always
-- explainable rather than a magic number.
create table if not exists public.sme_lead_score_weights (
  signal_key text primary key,
  label text not null,
  weight smallint not null,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  constraint sme_lead_score_weights_range check (weight between 0 and 100)
);
alter table public.sme_lead_score_weights enable row level security;
revoke all on table public.sme_lead_score_weights from public, anon, authenticated;

create table if not exists public.sme_lead_scores (
  prospect_id uuid primary key references public.sme_prospects(id) on delete cascade,
  score smallint not null,
  score_breakdown jsonb not null default '[]'::jsonb,
  computed_at timestamptz not null default now(),
  constraint sme_lead_scores_range check (score between 0 and 100)
);
alter table public.sme_lead_scores enable row level security;
revoke all on table public.sme_lead_scores from public, anon, authenticated;
create index if not exists sme_lead_scores_score_idx on public.sme_lead_scores(score desc);

-- ---------------------------------------------------------------- discovery audit
-- Every provider run is recorded with its call counts, so spend is auditable and
-- an unrestricted bulk job would be conspicuous rather than silent.
create table if not exists public.sme_discovery_runs (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'google_places',
  request jsonb not null default '{}'::jsonb,
  status text not null default 'preview',
  found_count integer not null default 0,
  new_count integer not null default 0,
  existing_count integer not null default 0,
  search_calls integer not null default 0,
  detail_calls integer not null default 0,
  error_text text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint sme_discovery_runs_status_check
    check (status in ('preview','importing','completed','failed'))
);
alter table public.sme_discovery_runs enable row level security;
revoke all on table public.sme_discovery_runs from public, anon, authenticated;
create index if not exists sme_discovery_runs_created_idx
  on public.sme_discovery_runs(created_at desc);

-- ------------------------------------------------- contact channel enrichment
-- The existing contacts table has no WhatsApp number and no contact type; the
-- brief needs both. Added in place so the shipped contacts UI keeps working.
alter table public.sme_prospect_contacts
  add column if not exists whatsapp_number text,
  add column if not exists contact_type text;

-- =================================================================== helpers
-- Shared authorization for the whole prospecting surface. Mirrors the v267 rule:
-- admin/super-admin see everything; a sales_staff is confined to their own book.
create or replace function app.v297_can_prospecting(p_mode text default 'r')
returns boolean language sql stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(
    app.is_super_admin()
    or (app.v89_platform_role() in ('admin','sales_staff')
        and app.v89_platform_can('onboarding', p_mode)),
  false)
$$;

create or replace function app.v297_assert_prospecting(p_mode text default 'r')
returns void language plpgsql stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if not app.v297_can_prospecting(p_mode) then
    raise exception 'prospecting_access_required' using errcode='42501';
  end if;
end $$;

-- Exact great-circle distance in km. Used only AFTER a bounding-box prefilter has
-- cut the candidate set, so the trig cost is paid on tens of rows, not the table.
create or replace function app.v297_haversine_km(
  p_lat1 double precision, p_lng1 double precision,
  p_lat2 double precision, p_lng2 double precision
) returns double precision language sql immutable
set search_path to 'pg_catalog','pg_temp' as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(p_lat2 - p_lat1) / 2), 2)
    + cos(radians(p_lat1)) * cos(radians(p_lat2))
      * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
  ))
$$;

-- Lead score: 0-100, weights come from the table, and the breakdown explains every
-- point awarded. Deliberately NOT presented as predictive — it is a ranking aid.
create or replace function app.v297_lead_score(p_prospect uuid)
returns jsonb language plpgsql stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_row record;
  v_score integer := 0;
  v_parts jsonb := '[]'::jsonb;
  v_w record;
  v_award integer;
  v_hit boolean;
begin
  select p.id, p.current_stage_key, p.converted_business_id, p.assigned_consultant_id,
         c.phone as company_phone, c.website as company_website, c.email as company_email,
         f.rating, f.review_count, f.business_status,
         l.planning_area, l.latitude, l.longitude,
         (select count(*) from public.sme_prospect_contacts ct
           where ct.prospect_id=p.id and ct.active
             and coalesce(nullif(btrim(ct.whatsapp_number),''), nullif(btrim(ct.phone),'')) is not null
         ) as reachable_contacts
    into v_row
    from public.sme_prospects p
    join public.sme_companies c on c.id = p.company_id
    left join public.sme_company_market_facts f on f.company_id = c.id
    left join public.sme_company_locations l on l.company_id = c.id and l.is_primary
   where p.id = p_prospect;
  if not found then return jsonb_build_object('score',0,'breakdown','[]'::jsonb); end if;

  for v_w in select * from public.sme_lead_score_weights where active order by signal_key loop
    v_hit := false;
    v_award := 0;
    if v_w.signal_key = 'rating_high' and coalesce(v_row.rating,0) >= 4.2 then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'review_volume' and coalesce(v_row.review_count,0) >= 100 then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'has_phone'
      and (nullif(btrim(coalesce(v_row.company_phone,'')),'') is not null or v_row.reachable_contacts > 0) then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'has_website'
      and nullif(btrim(coalesce(v_row.company_website,'')),'') is not null then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'has_email'
      and nullif(btrim(coalesce(v_row.company_email,'')),'') is not null then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'operational'
      and coalesce(v_row.business_status,'OPERATIONAL') = 'OPERATIONAL' then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'geocoded' and v_row.latitude is not null then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'not_yet_merchant' and v_row.converted_business_id is null then
      v_hit := true; v_award := v_w.weight;
    elsif v_w.signal_key = 'uncontacted'
      and not exists (select 1 from public.sme_outreach_records o where o.prospect_id = v_row.id) then
      v_hit := true; v_award := v_w.weight;
    end if;
    if v_hit then
      v_score := v_score + v_award;
      v_parts := v_parts || jsonb_build_array(jsonb_build_object(
        'key', v_w.signal_key, 'label', v_w.label, 'points', v_award));
    end if;
  end loop;

  v_score := least(100, greatest(0, v_score));
  return jsonb_build_object('score', v_score, 'breakdown', v_parts);
end $$;

-- Materialize the score so the list can ORDER BY it without a per-row function call.
create or replace function app.v297_refresh_lead_score(p_prospect uuid)
returns void language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v jsonb;
begin
  v := app.v297_lead_score(p_prospect);
  insert into public.sme_lead_scores(prospect_id, score, score_breakdown, computed_at)
  values (p_prospect, (v->>'score')::smallint, v->'breakdown', now())
  on conflict (prospect_id) do update
    set score = excluded.score,
        score_breakdown = excluded.score_breakdown,
        computed_at = now();
end $$;

commit;
