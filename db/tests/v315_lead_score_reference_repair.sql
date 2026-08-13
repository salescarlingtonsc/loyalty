-- Rollback-only acceptance for v315: repair of the dropped-lead-score references.
--
-- v313 dropped app.v297_lead_score, app.v297_refresh_lead_score and
-- public.sme_lead_scores, but five production functions still called those
-- objects. PL/pgSQL resolves names at RUN time, not at definition time, so
-- nothing failed until each function was actually invoked -- including a
-- pg_cron retention sweep that would have failed silently every night. The
-- assertions here are the ones that would have caught the original bug:
--   A. no function anywhere still references the dropped objects;
--   B. the full sales workflow (import, search, assign, log outreach, open
--      the drawer, run the superseded search, purge retention, funnel) all
--      execute cleanly, end to end, as a real caller would exercise them.
begin;

do $v315$
declare
  v_sa uuid; v_consultant uuid; v_prospect uuid; v_outreach_id uuid; v_bad text;
  d jsonb; n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- ------------------------------------------------------------------- A
  -- No function in public or app may still reference a dropped lead-score
  -- object. This is the guard that would have caught the original bug: a
  -- future drop of scoring infrastructure cannot silently re-break these
  -- five callers again.
  select string_agg(n.nspname||'.'||p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app') and p.prokind='f'
     -- Match the whole lead-score FAMILY, not three exact names. The first cut
     -- of this guard searched for 'sme_lead_scores' and therefore could not see
     -- 'sme_lead_score_weights', which was still referenced by the taxonomy RPC
     -- and took the entire Prospecting route down.
     and pg_get_functiondef(p.oid) like '%lead_score%';
  if v_bad is not null then
    raise exception 'A: lead-score references still present in: %', v_bad;
  end if;

  -- ------------------------------------------------------------------- B
  -- 1. Import a single fabricated place and commit it.
  d := public.platform_crm_ingest_discovered_v297(
    jsonb_build_array(jsonb_build_object(
      'source_id','ZZ_V315_PLACE','name','V315 Probe Cafe',
      'category_key','fnb_cafe','planning_area','Hougang','postal_code','530123',
      'latitude',1.3713,'longitude',103.8924,'geo_source','onemap',
      'rating',4.4,'review_count',120,'phone','81110000')),
    '{}'::jsonb, true, 0, 0);
  if (d->>'new')::int <> 1 then
    raise exception 'B1: expected new=1, got %', d->>'new';
  end if;

  select p.id into v_prospect
    from public.sme_prospects p
    join public.sme_companies c on c.id = p.company_id
    join public.sme_company_sources src on src.company_id = c.id
   where src.source_id = 'ZZ_V315_PLACE';
  if v_prospect is null then
    raise exception 'B1: the imported prospect could not be located';
  end if;

  -- 2. The Business Explorer must find exactly the one prospect.
  d := public.platform_explorer_search_v312(
    jsonb_build_object('q','V315 Probe Cafe'), 'list', 'added_desc', 50, 0);
  if (d->>'total')::int <> 1 then
    raise exception 'B2: expected total=1, got %', d->>'total';
  end if;

  -- 3. Bulk-assign to a consultant.
  select id into v_consultant from public.platform_consultants limit 1;
  if v_consultant is null then
    raise exception 'B3: no platform consultant is configured to assign to';
  end if;
  d := public.platform_explorer_bulk_assign_v312(
    array[v_prospect], v_consultant, 'v315 acceptance');
  if (d->>'assigned')::int <> 1 then
    raise exception 'B3: expected assigned=1, got %', d->>'assigned';
  end if;

  -- 4. Log outreach against the prospect.
  d := public.platform_crm_log_outreach_v297(
    v_prospect, 'call', 'follow_up', 'probe', null,
    now() + interval '2 days', 'v315-key');
  v_outreach_id := nullif(d->>'outreach_id','')::uuid;
  if v_outreach_id is null then
    raise exception 'B4: expected an outreach_id, got %', d;
  end if;

  -- 5. The prospect drawer must open without a lead_score reference anywhere
  --    in its payload.
  d := public.platform_crm_prospecting_detail_v297(v_prospect);
  if d::text like '%lead_score%' then
    raise exception 'B5: prospect detail payload still mentions lead_score: %', d::text;
  end if;

  -- 6. The superseded search surface (list and markers modes) must still
  --    execute -- it is superseded, not deleted, and must not throw.
  perform public.platform_crm_prospecting_search_v297('{}'::jsonb,'list',5,0);
  perform public.platform_crm_prospecting_search_v297('{}'::jsonb,'markers',5,0);

  -- 7. The nightly Google-content retention sweep must execute and return
  --    the two counters it always has.
  d := app.v310_purge_expired_google_content();
  if not (d ? 'expired_geo_rows' and d ? 'expired_fact_rows') then
    raise exception 'B7: retention sweep payload missing expected keys: %', d::text;
  end if;

  -- 8. The conversion funnel must execute.
  perform public.platform_conversion_funnel_v312(null, null);

  -- 9. Every remaining RPC the Prospecting route calls on load. The taxonomy one
  --    is first in that route, so when it raised, the whole page rendered
  --    "Prospecting unavailable" and nothing else got a chance to run.
  d := public.platform_crm_prospecting_taxonomy_v297();
  if d::text like '%score%' then
    raise exception 'B9: taxonomy still exposes a scoring key: %', d::text;
  end if;
  perform public.platform_crm_prospecting_summary_v297();
  perform public.platform_crm_saved_filters_v297();
  perform public.platform_crm_stale_google_sources_v297(50);
  perform public.platform_merchant_matches_v312(50);
  perform public.platform_explorer_search_v312('{}'::jsonb,'markers','added_desc',500,0);
  perform public.platform_explorer_search_v312('{}'::jsonb,'ids','added_desc',25,0);
  perform public.platform_explorer_search_v312('{}'::jsonb,'count','name_asc',25,0);

  raise notice 'v315 lead-score reference repair: all assertions passed';
end $v315$;

rollback;
