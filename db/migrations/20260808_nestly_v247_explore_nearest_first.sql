-- Nestly v247 — Explore can sort by distance, once a branch has a location.
--
-- Owner: "yes please add the geocoding + nearest first sorting."
--
-- v245 shipped Explore as a catalogue search. "Nearest first" needs three things this platform
-- did not have: somewhere to keep a branch's coordinates, a distance the SERVER can order by, and
-- an honest answer for the businesses that have no location yet.
--
--   1. branches.latitude / longitude, plus the provenance a geocoded value must carry:
--      geocoded_address (the exact text the coordinates were derived from), geocoded_at and
--      geocode_source. Provenance is what makes the value re-checkable — if the branch address is
--      edited later, geocoded_address no longer matches and scripts/geo/geocode-branches.mjs
--      re-geocodes it. A coordinate with no record of where it came from is a guess.
--
--   2. app.v247_distance_km — plain haversine on a 6371 km sphere. No PostGIS: the directory is
--      tens of rows, every input is already in the row being scanned, and the earth's curvature
--      over Singapore costs less accuracy than the address itself. The shape moves to
--      earthdistance or PostGIS later without a contract change.
--
--   3. customer_explore_businesses_v244 takes p_lat/p_lng. When both are given and valid, results
--      order by distance ascending with unlocated businesses LAST — never dropped, because a
--      business the customer already belongs to must not vanish from Explore just because its
--      owner has not typed an address. Each row carries distance_km (null when unknown), so the
--      customer sees "1.2 km" or nothing, never a fabricated position.
--
-- Without coordinates the function behaves exactly as v245 did. The old single-argument signature
-- is dropped and replaced by one with defaults, so a client that still sends only p_query keeps
-- resolving — verified before this shipped.
--
-- Privacy: the customer's coordinates are function ARGUMENTS. They are never stored, never
-- logged, and never written to any row; they exist for the duration of one query.

begin;

alter table public.branches
  add column if not exists latitude numeric(9,6),
  add column if not exists longitude numeric(9,6),
  add column if not exists geocoded_address text,
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocode_source text;

comment on column public.branches.latitude is
  'v247: WGS84 latitude of this branch, set by geocoding branches.address. Null until located.';
comment on column public.branches.geocoded_address is
  'v247: the exact address text the coordinates were derived from. When it no longer matches '
  'branches.address, the coordinates are stale and the geocoder re-runs.';

-- a coordinate pair is all-or-nothing, and must be on the planet
alter table public.branches
  drop constraint if exists branches_v247_location_pair;
alter table public.branches
  add constraint branches_v247_location_pair check (
    (latitude is null and longitude is null)
    or (latitude between -90 and 90 and longitude between -180 and 180)
  );

create or replace function app.v247_distance_km(
  p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric
) returns numeric
language sql
immutable
parallel safe
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when p_lat1 is null or p_lng1 is null or p_lat2 is null or p_lng2 is null then null
    else round((
      6371 * 2 * asin(least(1, sqrt(
        power(sin(radians(p_lat2 - p_lat1) / 2), 2)
        + cos(radians(p_lat1)) * cos(radians(p_lat2))
        * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
      )))
    )::numeric, 2)
  end;
$$;

comment on function app.v247_distance_km(numeric,numeric,numeric,numeric) is
  'v247: great-circle distance in km between two WGS84 points (haversine, 6371 km sphere).';

revoke all on function app.v247_distance_km(numeric,numeric,numeric,numeric) from public, anon, authenticated;

-- The single-argument signature goes so the defaulted one below cannot be ambiguous with it.
-- A client that sends only p_query still resolves to the new function.
drop function if exists public.customer_explore_businesses_v244(text);

create or replace function public.customer_explore_businesses_v244(
  p_query text default null,
  p_lat numeric default null,
  p_lng numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_tokens text[];
  v_lat numeric;
  v_lng numeric;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer required' using errcode='28000';
  end if;

  -- an out-of-range or half-supplied position is treated as no position at all, never clamped
  if p_lat between -90 and 90 and p_lng between -180 and 180 then
    v_lat := p_lat;
    v_lng := p_lng;
  end if;

  select coalesce(array_agg(word), '{}')
    into v_tokens
  from (
    select lower(word) as word
    from regexp_split_to_table(coalesce(p_query,''), '[^[:alnum:]]+') word
    where length(word) between 2 and 40
      and lower(word) not in ('near','me','nearby','the','shop','shops','store','stores','place','places','in','at','for','a','an')
    limit 6
  ) cleaned;

  select coalesce(jsonb_agg(entry order by
      -- nearest first when the customer shared a position; unlocated businesses last, never gone
      (case when v_lat is null then 0 else 1 end) * coalesce((entry->>'distance_km')::numeric, 999999),
      (entry->>'joined') desc,
      entry->>'name'
    ), '[]'::jsonb)
    into v_result
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'name', b.name,
      'slug', b.slug,
      'brand_color', b.brand_color,
      'industry', b.industry,
      'logo_url', app.v95_public_media_url(logo.object_path),
      'joined', (cl.id is not null),
      'points_balance', case when cl.id is null then null else coalesce((
        select sum(pl.points) from public.points_ledger pl
         where pl.business_id = b.id and pl.client_id = cl.client_id), 0) end,
      'earn_points_per_dollar', lp.earn_points_per_dollar,
      'loyalty_model', lp.loyalty_model,
      'points_mode', b.points_mode,
      'address', branch.address,
      'phone', branch.phone,
      'distance_km', app.v247_distance_km(v_lat, v_lng, branch.latitude, branch.longitude),
      'located', (branch.latitude is not null and branch.longitude is not null),
      'booking_enabled', coalesce(b.booking_policy is not null and exists(
        select 1 from public.services s where s.business_id=b.id and s.active), false),
      'match_note', matched.note
    ) as entry
    from public.businesses b
    left join public.customer_links cl
      on cl.business_id = b.id and cl.auth_user_id = v_actor
     and cl.state = 'verified' and cl.unlinked_at is null
    left join public.loyalty_programs lp
      on lp.business_id = b.id and lp.active
    left join public.business_brand_presentation_v95 brand
      on brand.business_id = b.id
    left join public.business_media_assets_v95 logo
      on logo.id = brand.logo_asset_id and logo.business_id = b.id
     and logo.asset_kind = 'logo' and logo.customer_visible
    left join lateral (
      /* the branch a customer would actually walk into: the nearest LOCATED one when a position
         was shared, otherwise the default. A firm with ten outlets is as far away as its closest
         outlet, not as far away as whichever row happened to sort first. */
      select br.address, br.phone, br.latitude, br.longitude
      from public.branches br
      where br.business_id = b.id and coalesce(br.active,true)
      order by
        case when v_lat is null then null
             else app.v247_distance_km(v_lat, v_lng, br.latitude, br.longitude) end
          nulls last,
        br.is_default desc, br.created_at, br.id
      limit 1
    ) branch on true
    left join lateral (
      select min(item.name) as note
      from (
        select s.name from public.services s where s.business_id=b.id and s.active
        union all
        select p.name from public.products p where p.business_id=b.id and coalesce(p.active,true)
      ) item
      where cardinality(v_tokens) > 0
        and exists(select 1 from unnest(v_tokens) t where item.name ilike '%'||t||'%')
    ) matched on true
    where b.join_enabled
      and (
        cardinality(v_tokens) = 0
        or not exists (
          select 1 from unnest(v_tokens) t
          where not (
            b.name ilike '%'||t||'%'
            or coalesce(b.industry,'') ilike '%'||t||'%'
            or exists(select 1 from public.services s
                       where s.business_id=b.id and s.active and s.name ilike '%'||t||'%')
            or exists(select 1 from public.products p
                       where p.business_id=b.id and coalesce(p.active,true) and p.name ilike '%'||t||'%')
          )
        )
      )
  ) listed;

  return v_result;
end
$function$;

comment on function public.customer_explore_businesses_v244(text,numeric,numeric) is
  'v247: Explore search with optional nearest-first ordering. The customer position is an argument '
  'only — never stored. Businesses with no located branch sort last and carry distance_km null.';

revoke all on function public.customer_explore_businesses_v244(text,numeric,numeric) from public, anon;
grant execute on function public.customer_explore_businesses_v244(text,numeric,numeric) to authenticated;

commit;
