-- Rollback-only acceptance for the v297-v299 Merchant Prospecting CRM + Map.
--
-- Walks the brief's own worked example end to end — discovery -> segmentation ->
-- map -> prospect selection -> outreach -> follow-up — against the REAL production
-- functions, using the brief's §18 test business (Hougang Cafe, 81863833,
-- Blk 123 Hougang), then rolls everything back.
--
-- The assertions that matter most are the ones a reviewer would not think to write:
--   * a PREVIEW must not write anything at all;
--   * a repeat discovery must NOT create a second company (the whole cost story);
--   * a repeat discovery must NOT overwrite a curated field, but MUST refresh the
--     provider-owned one — the two halves of brief §15;
--   * a radius filter must exclude a business that is genuinely far away, not just
--     include the near one (a filter that returns everything passes a naive test).
begin;

do $v297$
declare v_sa uuid; d jsonb; v_prospect uuid; v_run jsonb; n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- A. Filter bootstrap carries the full data-driven taxonomy.
  d := public.platform_crm_prospecting_taxonomy_v297();
  if jsonb_array_length(d->'sectors') < 6 then raise exception 'A: sectors'; end if;
  if jsonb_array_length(d->'categories') < 25 then
    raise exception 'A: categories %', jsonb_array_length(d->'categories'); end if;
  if jsonb_array_length(d->'planning_areas') < 30 then raise exception 'A: planning areas'; end if;
  if (d->>'can_assign')::boolean is not true then raise exception 'A: SA must be able to assign'; end if;

  -- B. PREVIEW must report the work without performing it.
  v_run := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(jsonb_build_object('source','google_places','source_id','ZZ_V297_PLACE_1',
      'name','Hougang Cafe','phone','81863833','address','Blk 123 Hougang','postal_code','530123',
      'planning_area','Hougang','latitude',1.3713,'longitude',103.8924,'rating',4.5,
      'review_count',260,'price_level',2,'business_status','OPERATIONAL','category_key','fnb_cafe')),
    '{}'::jsonb, false, 1, 0);
  if (v_run->>'new')::int <> 1 then raise exception 'B: preview counts %', v_run; end if;
  if exists(select 1 from public.sme_company_sources where source_id='ZZ_V297_PLACE_1') then
    raise exception 'B: a PREVIEW wrote data';
  end if;

  -- C. Commit builds the whole graph (company + source + location + facts + prospect).
  v_run := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(jsonb_build_object('source','google_places','source_id','ZZ_V297_PLACE_1',
      'name','Hougang Cafe','phone','81863833','address','Blk 123 Hougang','postal_code','530123',
      'planning_area','Hougang','latitude',1.3713,'longitude',103.8924,'rating',4.5,
      'review_count',260,'price_level',2,'business_status','OPERATIONAL','category_key','fnb_cafe')),
    '{}'::jsonb, true, 1, 1);
  if (v_run->>'new')::int <> 1 then raise exception 'C: commit %', v_run; end if;

  -- D. DEDUP + the curated/provider split.
  v_run := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(jsonb_build_object('source','google_places','source_id','ZZ_V297_PLACE_1',
      'name','Hougang Cafe RENAMED BY PROVIDER','rating',4.7)), '{}'::jsonb, true, 1, 0);
  if (v_run->>'existing')::int <> 1 or (v_run->>'new')::int <> 0 then
    raise exception 'D: dedup did not recognise the place %', v_run; end if;
  select count(*) into n from public.sme_company_sources where source_id='ZZ_V297_PLACE_1';
  if n <> 1 then raise exception 'D: % source rows for one place', n; end if;
  if (select legal_name from public.sme_companies c
        join public.sme_company_sources s on s.company_id=c.id
       where s.source_id='ZZ_V297_PLACE_1') <> 'Hougang Cafe' then
    raise exception 'D: a re-sync overwrote a curated field';
  end if;
  if (select rating from public.sme_company_market_facts f
        join public.sme_company_sources s on s.company_id=f.company_id
       where s.source_id='ZZ_V297_PLACE_1') <> 4.7 then
    raise exception 'D: the provider-owned fact did not refresh';
  end if;

  select p.id into v_prospect from public.sme_prospects p
    join public.sme_company_sources s on s.company_id=p.company_id
   where s.source_id='ZZ_V297_PLACE_1';

  -- E. The brief's worked combined filter.
  d := public.platform_crm_prospecting_search_v297(jsonb_build_object(
        'planning_areas',jsonb_build_array('Hougang'),'sectors',jsonb_build_array('fnb'),
        'categories',jsonb_build_array('fnb_cafe'),'rating_min',4.2,'review_min',100,
        'outreach','not_contacted','has_phone',true),'list',50,0);
  if (d->>'total')::int <> 1 then raise exception 'E: combined filter total %', d->>'total'; end if;
  if d#>>'{rows,0,name}' <> 'Hougang Cafe' then raise exception 'E: wrong row returned'; end if;

  -- F. Radius must EXCLUDE as well as include.
  d := public.platform_crm_prospecting_search_v297(jsonb_build_object(
        'radius',jsonb_build_object('lat',1.3713,'lng',103.8924,'km',2)),'markers',50,0);
  if (d->>'total')::int < 1 then raise exception 'F: 2km of Hougang MRT missed it'; end if;
  if d#>>'{markers,0,lat}' is null then raise exception 'F: marker carries no geometry'; end if;
  d := public.platform_crm_prospecting_search_v297(jsonb_build_object(
        'radius',jsonb_build_object('lat',1.3496,'lng',103.9568,'km',2)),'markers',50,0);
  if (d->>'total')::int <> 0 then
    raise exception 'F: 2km of Tampines wrongly matched a Hougang business (%)', d->>'total'; end if;

  -- G. Map viewport.
  d := public.platform_crm_prospecting_search_v297(jsonb_build_object(
        'bbox',jsonb_build_object('north',1.40,'south',1.34,'east',103.92,'west',103.86)),'markers',50,0);
  if (d->>'total')::int < 1 then raise exception 'G: bbox missed it'; end if;

  -- H. Lead score is present AND explainable.
  d := public.platform_crm_prospecting_detail_v297(v_prospect);
  if (d#>>'{lead_score,score}')::int < 40 then
    raise exception 'H: score too low %', d->'lead_score'; end if;
  if jsonb_array_length(d#>'{lead_score,breakdown}') < 5 then
    raise exception 'H: score is not explainable'; end if;
  if d#>>'{location,planning_area}' <> 'Hougang' then raise exception 'H: location missing'; end if;

  -- I. follow_up without a date is refused rather than silently dropped.
  begin
    perform public.platform_crm_log_outreach_v297(v_prospect,'call','follow_up','x',null,null,null);
    raise exception 'I: follow_up was accepted without a date';
  exception when sqlstate '22023' then null; end;

  -- J. Outreach flips the CRM state and creates the follow-up in the EXISTING task table.
  d := public.platform_crm_prospecting_search_v297(
        jsonb_build_object('q','Hougang Cafe','outreach','not_contacted'),'list',50,0);
  if (d->>'total')::int <> 1 then raise exception 'J0: should start uncontacted'; end if;
  d := public.platform_crm_log_outreach_v297(v_prospect,'whatsapp','follow_up',
        'Spoke to owner, call back Friday', null, now()+interval '3 days', 'k1');
  if d->>'outreach_id' is null then raise exception 'J: no outreach id'; end if;
  if not exists(select 1 from public.sme_prospect_tasks where prospect_id=v_prospect) then
    raise exception 'J: follow-up task was not created in sme_prospect_tasks'; end if;
  d := public.platform_crm_prospecting_search_v297(
        jsonb_build_object('q','Hougang Cafe','outreach','not_contacted'),'list',50,0);
  if (d->>'total')::int <> 0 then raise exception 'J1: still reads as uncontacted'; end if;
  d := public.platform_crm_prospecting_search_v297(
        jsonb_build_object('q','Hougang Cafe','outreach','follow_up'),'list',50,0);
  if (d->>'total')::int <> 1 then raise exception 'J2: follow_up filter missed it'; end if;
  d := public.platform_crm_prospecting_search_v297(
        jsonb_build_object('q','Hougang Cafe','follow_up','due_today'),'list',50,0);
  if (d->>'total')::int <> 0 then raise exception 'J3: a 3-day-out follow-up read as due today'; end if;
  d := public.platform_crm_prospecting_search_v297(
        jsonb_build_object('q','Hougang Cafe','contacted_within_days','7'),'list',50,0);
  if (d->>'total')::int <> 1 then raise exception 'J4: contacted_within_days missed it'; end if;

  -- J5. A double-tap on Log contact must not create a second record.
  d := public.platform_crm_log_outreach_v297(v_prospect,'whatsapp','follow_up',
        'Spoke to owner, call back Friday', null, now()+interval '3 days', 'k1');
  if (d->>'replayed')::boolean is not true then raise exception 'J5: not idempotent'; end if;
  select count(*) into n from public.sme_outreach_records where prospect_id=v_prospect;
  if n <> 1 then raise exception 'J5: % outreach rows after a replay', n; end if;

  -- K. Saved filters round-trip.
  d := public.platform_crm_save_filter_v297('Hot F&B Prospects',
        jsonb_build_object('sectors',jsonb_build_array('fnb'),'rating_min',4.3));
  if d->>'id' is null then raise exception 'K: save failed'; end if;
  if jsonb_array_length(public.platform_crm_saved_filters_v297()) < 1 then
    raise exception 'K: saved filter did not list'; end if;

  -- L. Dashboard reflects the work just done.
  d := public.platform_crm_prospecting_summary_v297();
  if (d->>'contacted')::int < 1 then raise exception 'L: summary contacted %', d; end if;
  if jsonb_array_length(d->'pipeline') < 19 then raise exception 'L: pipeline stages missing'; end if;

  raise notice 'v297 merchant prospecting CRM + map: all assertions passed';
end $v297$;

rollback;
