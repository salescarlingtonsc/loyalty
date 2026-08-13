-- Rollback-only acceptance for v310: Google Maps content retention.
--
-- Proves the four compliance behaviours the migration claims:
--   * expired google-sourced coordinates are DELETED (GMP SST §14.3), while
--     OneMap-sourced coordinates (SG open data) survive the same sweep;
--   * place IDs survive forever (SST §3);
--   * a re-sync of a known place restores content and restarts its 30-day window;
--   * the stale-sources inventory nominates near-expiry places for refresh.
begin;

do $v310$
declare v_sa uuid; d jsonb; v_prospect uuid; n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- A. Ingest records geo provenance.
  d := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(
      jsonb_build_object('source','google_places','source_id','ZZ_V310_ONEMAP','name','OneMap Cafe',
        'postal_code','530123','latitude',1.3713,'longitude',103.8924,'address','Blk 123 Hougang',
        'geo_source','onemap','rating',4.4,'review_count',150,'category_key','fnb_cafe','planning_area','Hougang'),
      jsonb_build_object('source','google_places','source_id','ZZ_V310_GOOG','name','Google Geo Cafe',
        'latitude',1.30,'longitude',103.80,'address','No Postal St','rating',4.0,'review_count',80,
        'category_key','fnb_cafe','planning_area','Hougang')),
    '{}'::jsonb, true, 1, 1);
  if (d->>'new')::int <> 2 then raise exception 'A: ingest %', d; end if;
  if (select geo_source from public.sme_company_locations l
        join public.sme_company_sources s on s.company_id=l.company_id
       where s.source_id='ZZ_V310_ONEMAP') <> 'onemap' then
    raise exception 'A: onemap provenance not recorded'; end if;

  -- B. Age everything past 30 days, run the sweep.
  update public.sme_company_locations l set geo_synced_at = now() - interval '31 days'
   from public.sme_company_sources s
  where s.company_id=l.company_id and s.source_id in ('ZZ_V310_ONEMAP','ZZ_V310_GOOG');
  update public.sme_company_market_facts f set last_synced_at = now() - interval '31 days'
   from public.sme_company_sources s
  where s.company_id=f.company_id and s.source_id in ('ZZ_V310_ONEMAP','ZZ_V310_GOOG');

  d := app.v310_purge_expired_google_content();
  if (d->>'expired_fact_rows')::int < 2 then raise exception 'B: facts not purged %', d; end if;

  if (select latitude from public.sme_company_locations l
        join public.sme_company_sources s on s.company_id=l.company_id
       where s.source_id='ZZ_V310_GOOG') is not null then
    raise exception 'B: expired Google coordinates were NOT deleted'; end if;
  if (select latitude from public.sme_company_locations l
        join public.sme_company_sources s on s.company_id=l.company_id
       where s.source_id='ZZ_V310_ONEMAP') is null then
    raise exception 'B: OneMap coordinates were wrongly purged'; end if;

  select count(*) into n from public.sme_company_sources
   where source_id in ('ZZ_V310_ONEMAP','ZZ_V310_GOOG');
  if n <> 2 then raise exception 'B: place IDs must survive the purge'; end if;

  -- C. Lead score dropped honestly after the facts purge.
  select p.id into v_prospect from public.sme_prospects p
    join public.sme_company_sources s on s.company_id=p.company_id
   where s.source_id='ZZ_V310_ONEMAP';
  d := public.platform_crm_prospecting_detail_v297(v_prospect);
  if (d#>'{lead_score,breakdown}')::text like '%rating_high%' then
    raise exception 'C: purged rating still scoring'; end if;

  -- D. Re-sync of an EXISTING company restores content and restarts the window.
  d := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(jsonb_build_object('source','google_places','source_id','ZZ_V310_GOOG',
      'name','Google Geo Cafe','latitude',1.30,'longitude',103.80,'rating',4.1)),
    '{}'::jsonb, true, 1, 0);
  if (d->>'existing')::int <> 1 then raise exception 'D: resync %', d; end if;
  if (select latitude from public.sme_company_locations l
        join public.sme_company_sources s on s.company_id=l.company_id
       where s.source_id='ZZ_V310_GOOG') is null then
    raise exception 'D: resync did not restore coordinates'; end if;
  if (select geo_synced_at > now() - interval '1 minute' from public.sme_company_locations l
        join public.sme_company_sources s on s.company_id=l.company_id
       where s.source_id='ZZ_V310_GOOG') is not true then
    raise exception 'D: retention window not restarted'; end if;

  -- E. Stale inventory nominates near-expiry sources for the refresh flow.
  update public.sme_company_market_facts f set last_synced_at = now() - interval '26 days'
   from public.sme_company_sources s
  where s.company_id=f.company_id and s.source_id='ZZ_V310_GOOG';
  d := public.platform_crm_stale_google_sources_v297(50);
  if d::text not like '%ZZ_V310_GOOG%' then raise exception 'E: stale list missed it'; end if;

  -- F. The retention cron is scheduled.
  if not exists (select 1 from cron.job where jobname='v310-google-content-retention') then
    raise exception 'F: retention cron not scheduled'; end if;

  raise notice 'v310 google content retention: all assertions passed';
end $v310$;

rollback;
