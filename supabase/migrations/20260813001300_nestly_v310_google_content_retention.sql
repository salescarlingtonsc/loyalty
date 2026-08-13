-- nestly_v310_google_content_retention
--
-- Enforces the Google Maps Platform Service Specific Terms (read live 2026-08-13,
-- cloud.google.com/maps-platform/terms) over the v297 prospecting CRM:
--
--   §3    Place IDs may be cached indefinitely            -> sme_company_sources rows are permanent.
--   §14.3 Places latitude/longitude may be cached for at  -> geo_source/geo_synced_at provenance columns
--         most 30 consecutive calendar days, then must       + a daily purge job that deletes expired
--         be deleted.                                        google-sourced coordinates.
--   (no allowance) name/rating/review counts/status/      -> sme_company_market_facts rows are treated as
--         phone/website have NO storage allowance.           transient: deleted outright after 30 days
--                                                            unless a refresh re-fetch restarts the clock.
--   §14.2 Places content must not be used with a          -> discovery re-geocodes every postal code via
--         non-Google map (Peekaa's map is a self-drawn       OneMap (SLA open government data); those
--         SVG).                                              coordinates carry geo_source='onemap' and are
--                                                            permanent, first-party-clean map data.
--
-- Peekaa's own CRM/sales data (companies, prospects, stages, outreach, tasks,
-- notes, assignments) is never touched by the purge — only provider-derived
-- content expires. geo_source='manual' marks human-verified locations that no
-- provider sync may overwrite.

begin;

-- ---------------------------------------------------------------------------
-- 1. Geo provenance on locations
-- ---------------------------------------------------------------------------
alter table public.sme_company_locations
  add column if not exists geo_source text not null default 'google_places',
  add column if not exists geo_synced_at timestamptz not null default now();

comment on column public.sme_company_locations.geo_source is
  'onemap = SG open data (permanent) | google_places = Google content (30-day purge) | manual = human-entered (permanent)';

-- ---------------------------------------------------------------------------
-- 2. The daily retention sweep
-- ---------------------------------------------------------------------------
create or replace function app.v310_purge_expired_google_content()
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_geo integer := 0; v_facts integer := 0; v_prospect uuid;
begin
  -- §14.3: google-sourced coordinates older than 30 days are deleted. The
  -- address/postal that came from Google go with them (no storage allowance).
  with expired as (
    update public.sme_company_locations l
       set latitude=null, longitude=null, address=null, postal_code=null
     where l.geo_source='google_places'
       and l.geo_synced_at < now() - interval '30 days'
       and (l.latitude is not null or l.address is not null or l.postal_code is not null)
    returning l.company_id
  ) select count(*) into v_geo from expired;

  -- Provider market facts (rating/reviews/status/price/phone/website) have no
  -- storage allowance in the current terms; 30 days is this system's OUTER
  -- transient bound, enforced by deletion. A refresh re-fetch restarts the window.
  with expired as (
    delete from public.sme_company_market_facts f
     where f.last_synced_at < now() - interval '30 days'
    returning f.company_id
  ) select count(*) into v_facts from expired;

  -- Scores that leaned on purged facts must drop honestly.
  for v_prospect in
    select p.id from public.sme_prospects p
     where p.archived_at is null
       and not exists (select 1 from public.sme_company_market_facts f
                        where f.company_id=p.company_id)
       and exists (select 1 from public.sme_lead_scores sc
                    where sc.prospect_id=p.id
                      and sc.score_breakdown::text like '%rating%')
  loop
    perform app.v297_refresh_lead_score(v_prospect);
  end loop;

  if v_geo > 0 or v_facts > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (null, null, 'GOOGLE_CONTENT_PURGED_V310', 'sme_company_market_facts', null,
            jsonb_build_object('expired_geo_rows', v_geo, 'expired_fact_rows', v_facts,
                               'policy', 'GMP SST §14.3 + no-storage posture'));
  end if;
  return jsonb_build_object('expired_geo_rows', v_geo, 'expired_fact_rows', v_facts);
end $function$;

-- Daily at 03:30 SGT (19:30 UTC), alongside the other retention crons.
do $cron$
begin
  if exists (select 1 from cron.job where jobname = 'v310-google-content-retention') then
    perform cron.unschedule('v310-google-content-retention');
  end if;
  perform cron.schedule('v310-google-content-retention', '30 19 * * *',
    $job$select app.v310_purge_expired_google_content()$job$);
end $cron$;

-- ---------------------------------------------------------------------------
-- 3. Refresh-before-expiry inventory (feeds the edge function's refresh mode)
-- ---------------------------------------------------------------------------
create or replace function public.platform_crm_stale_google_sources_v297(p_limit integer default 50)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  perform app.v297_assert_prospecting('rw');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'business_import_requires_admin' using errcode='42501';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'invalid_page_size' using errcode='22023';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'source_id', s.source_id, 'company_id', s.company_id))
    from (
      select distinct src.source_id, src.company_id
        from public.sme_company_sources src
        left join public.sme_company_market_facts f on f.company_id=src.company_id
        left join public.sme_company_locations l on l.company_id=src.company_id and l.is_primary
       where src.source='google_places'
         and (f.company_id is null
              or f.last_synced_at < now() - interval '25 days'
              or (l.geo_source='google_places' and l.geo_synced_at < now() - interval '25 days'))
       limit p_limit
    ) s),'[]'::jsonb);
end $function$;

revoke all on function public.platform_crm_stale_google_sources_v297(integer) from public, anon;
grant execute on function public.platform_crm_stale_google_sources_v297(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Ingest now records geo provenance and refreshes existing rows' windows
-- ---------------------------------------------------------------------------
create or replace function public.platform_crm_ingest_discovered_v297(
  p_places jsonb,
  p_request jsonb default '{}'::jsonb,
  p_commit boolean default false,
  p_search_calls integer default 0,
  p_detail_calls integer default 0)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_place jsonb; v_run uuid; v_company uuid; v_prospect uuid; v_category uuid;
  v_found integer := 0; v_new integer := 0; v_existing integer := 0;
  v_source text; v_source_id text; v_name text; v_geo_source text;
begin
  perform app.v297_assert_prospecting('rw');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'business_import_requires_admin' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_places,'null'::jsonb)) <> 'array' then
    raise exception 'places_payload_must_be_an_array' using errcode='22023';
  end if;

  insert into public.sme_discovery_runs(provider, request, status, search_calls, detail_calls, created_by)
  values (coalesce(p_request->>'provider','google_places'), coalesce(p_request,'{}'::jsonb),
          case when p_commit then 'importing' else 'preview' end,
          greatest(coalesce(p_search_calls,0),0), greatest(coalesce(p_detail_calls,0),0), auth.uid())
  returning id into v_run;

  for v_place in select * from jsonb_array_elements(p_places) loop
    v_found := v_found + 1;
    v_source := coalesce(nullif(btrim(v_place->>'source'),''),'google_places');
    v_source_id := nullif(btrim(v_place->>'source_id'),'');
    v_name := nullif(btrim(v_place->>'name'),'');
    v_geo_source := case when coalesce(v_place->>'geo_source','') = 'onemap'
                         then 'onemap' else 'google_places' end;
    if v_source_id is null or v_name is null then continue; end if;

    select company_id into v_company from public.sme_company_sources
     where source=v_source and source_id=v_source_id;

    if v_company is not null then
      v_existing := v_existing + 1;
      if p_commit then
        insert into public.sme_company_market_facts(
          company_id,business_status,rating,review_count,price_level,
          provider_phone,provider_website,last_synced_at,updated_at)
        values (v_company, v_place->>'business_status',
                nullif(v_place->>'rating','')::numeric, nullif(v_place->>'review_count','')::integer,
                nullif(v_place->>'price_level','')::smallint,
                v_place->>'phone', v_place->>'website', now(), now())
        on conflict (company_id) do update set
          business_status=coalesce(excluded.business_status,public.sme_company_market_facts.business_status),
          rating=coalesce(excluded.rating,public.sme_company_market_facts.rating),
          review_count=coalesce(excluded.review_count,public.sme_company_market_facts.review_count),
          price_level=coalesce(excluded.price_level,public.sme_company_market_facts.price_level),
          provider_phone=coalesce(excluded.provider_phone,public.sme_company_market_facts.provider_phone),
          provider_website=coalesce(excluded.provider_website,public.sme_company_market_facts.provider_website),
          last_synced_at=now(), updated_at=now();
        -- Refresh the retention window on the primary location too — but NEVER
        -- overwrite a manually-verified location (first-party beats provider).
        update public.sme_company_locations l
           set latitude=coalesce(nullif(v_place->>'latitude','')::double precision, l.latitude),
               longitude=coalesce(nullif(v_place->>'longitude','')::double precision, l.longitude),
               address=coalesce(nullif(v_place->>'address',''), l.address),
               postal_code=coalesce(nullif(v_place->>'postal_code',''), l.postal_code),
               geo_source=v_geo_source, geo_synced_at=now(), updated_at=now()
         where l.company_id=v_company and l.is_primary and l.geo_source <> 'manual';
        update public.sme_company_sources set last_synced_at=now()
         where source=v_source and source_id=v_source_id;
      end if;
      continue;
    end if;

    v_new := v_new + 1;
    if not p_commit then continue; end if;

    insert into public.sme_companies(legal_name, trading_name, phone, website)
    values (v_name, v_name, nullif(v_place->>'phone',''), nullif(v_place->>'website',''))
    returning id into v_company;

    insert into public.sme_company_sources(company_id,source,source_id,source_url,detail_fetched_at)
    values (v_company, v_source, v_source_id, nullif(v_place->>'source_url',''),
            case when (v_place ? 'rating') then now() end);

    insert into public.sme_company_locations(
      company_id,country,planning_area,district,address,postal_code,latitude,longitude,
      is_primary,geo_source,geo_synced_at)
    values (v_company, coalesce(nullif(v_place->>'country',''),'SG'),
            nullif(v_place->>'planning_area',''), nullif(v_place->>'district',''),
            nullif(v_place->>'address',''), nullif(v_place->>'postal_code',''),
            nullif(v_place->>'latitude','')::double precision,
            nullif(v_place->>'longitude','')::double precision, true,
            v_geo_source, now());

    insert into public.sme_company_market_facts(
      company_id,business_status,rating,review_count,price_level,
      provider_phone,provider_website,last_synced_at)
    values (v_company, v_place->>'business_status',
            nullif(v_place->>'rating','')::numeric, nullif(v_place->>'review_count','')::integer,
            nullif(v_place->>'price_level','')::smallint,
            v_place->>'phone', v_place->>'website', now());

    if nullif(v_place->>'category_key','') is not null then
      select id into v_category from public.sme_categories where category_key=v_place->>'category_key';
      if v_category is not null then
        insert into public.sme_company_categories(company_id,category_id,is_primary)
        values (v_company,v_category,true) on conflict do nothing;
      end if;
    end if;

    insert into public.sme_prospects(company_id,current_stage_key,created_by,updated_by)
    values (v_company,'new_lead',auth.uid(),auth.uid())
    returning id into v_prospect;
    perform app.v297_refresh_lead_score(v_prospect);
  end loop;

  update public.sme_discovery_runs
     set found_count=v_found, new_count=v_new, existing_count=v_existing,
         status=case when p_commit then 'completed' else 'preview' end,
         completed_at=now()
   where id=v_run;

  return jsonb_build_object('run_id',v_run,'committed',p_commit,
    'found',v_found,'new',v_new,'existing',v_existing,'duplicates',v_found-v_new-v_existing);
end $function$;

revoke all on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) from public, anon;
grant execute on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) to authenticated;

commit;
