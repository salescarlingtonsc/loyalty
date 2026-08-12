-- NESTLY v299 — the Prospecting RPC surface.
--
-- The v297 tables are definer-only (RLS on, zero browser-role grants). These
-- functions are the ONLY way in, and each one re-checks platform role rather than
-- trusting the caller. Scoping honours the standing owner rule (2026-08-10):
-- a sales_staff sees only prospects assigned to them; an admin sees the whole book;
-- ONLY the super admin assigns. Import additionally requires admin/super-admin,
-- because it mutates the shared prospect pool.
--
-- NOTE ON THE SEARCH FUNCTION. It is one CTE, not a temp table: PostgreSQL forbids
-- CREATE TABLE inside a STABLE function, and a single CTE also lets the planner see
-- the whole shape instead of materialising per call. It serves the list, the map
-- markers AND the totals from the SAME predicate set, which is what guarantees the
-- list and the map can never disagree about what "the current filter" means.

begin;

-- Filter bootstrap: everything the filter panel needs in ONE round trip.
create or replace function public.platform_crm_prospecting_taxonomy_v297()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
begin
  perform app.v297_assert_prospecting('r');
  return jsonb_build_object(
    'role', app.v89_platform_role(),
    'can_write', app.v297_can_prospecting('rw'),
    'can_assign', app.is_super_admin(),
    'sectors', coalesce((select jsonb_agg(jsonb_build_object(
        'key',s.sector_key,'label',s.label) order by s.sort_order)
      from public.sme_sectors s where s.active),'[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'key',c.category_key,'label',c.label,'sector',ps.sector_key,
        'parent',pc.category_key) order by ps.sort_order, c.sort_order)
      from public.sme_categories c
      join public.sme_sectors ps on ps.id=c.sector_id
      left join public.sme_categories pc on pc.id=c.parent_category_id
      where c.active),'[]'::jsonb),
    'planning_areas', coalesce((select jsonb_agg(jsonb_build_object(
        'name',a.name,'region',a.region,'lat',a.latitude,'lng',a.longitude)
        order by a.sort_order) from public.sme_planning_areas a),'[]'::jsonb),
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
        'key',st.stage_key,'label',st.label) order by st.sort_order)
      from public.sme_pipeline_stages st),'[]'::jsonb),
    'consultants', coalesce((select jsonb_agg(jsonb_build_object(
        'id',k.id,'name',k.display_name) order by k.display_name)
      from public.platform_consultants k where k.active),'[]'::jsonb),
    'score_weights', coalesce((select jsonb_agg(jsonb_build_object(
        'key',w.signal_key,'label',w.label,'weight',w.weight) order by w.weight desc)
      from public.sme_lead_score_weights w where w.active),'[]'::jsonb)
  );
end $fn$;

create or replace function public.platform_crm_prospecting_search_v297(
  p_filters jsonb default '{}'::jsonb,
  p_mode text default 'list',
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare
  v_self uuid; v_scoped boolean; v_result jsonb; v_marker_cap integer := 2000;
  v_q text; v_lat double precision; v_lng double precision; v_km double precision;
begin
  perform app.v297_assert_prospecting('r');
  if p_mode not in ('list','markers') then
    raise exception 'invalid_search_mode' using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'invalid_page_size' using errcode='22023';
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'invalid_page_offset' using errcode='22023';
  end if;
  v_scoped := app.v89_platform_role()='sales_staff' and not app.is_super_admin();
  v_self := app.v226_self_consultant();
  v_q := nullif(btrim(coalesce(p_filters->>'q','')),'');
  v_lat := nullif(p_filters#>>'{radius,lat}','')::double precision;
  v_lng := nullif(p_filters#>>'{radius,lng}','')::double precision;
  v_km  := nullif(p_filters#>>'{radius,km}','')::double precision;

  with hits as (
    select p.id as prospect_id, c.id as company_id,
           coalesce(nullif(btrim(c.trading_name),''), c.legal_name) as name,
           p.current_stage_key as stage_key,
           l.planning_area, l.district, l.address, l.postal_code, l.latitude, l.longitude,
           f.rating, f.review_count, f.price_level, f.business_status,
           coalesce(nullif(btrim(c.phone),''), f.provider_phone) as phone,
           coalesce(nullif(btrim(c.website),''), f.provider_website) as website,
           c.email,
           coalesce(sc.score,0) as score, p.assigned_consultant_id,
           k.display_name as assigned_name, p.converted_business_id,
           o.contacted_at as last_contacted_at, o.outcome as last_outcome,
           o.next_follow_up_at,
           case when v_lat is not null and l.latitude is not null
                then round(app.v297_haversine_km(v_lat,v_lng,l.latitude,l.longitude)::numeric,2)
           end as distance_km
      from public.sme_prospects p
      join public.sme_companies c on c.id=p.company_id
      left join public.sme_company_locations l on l.company_id=c.id and l.is_primary
      left join public.sme_company_market_facts f on f.company_id=c.id
      left join public.sme_lead_scores sc on sc.prospect_id=p.id
      left join public.platform_consultants k on k.id=p.assigned_consultant_id
      left join lateral (
        select r.contacted_at, r.outcome, r.next_follow_up_at
          from public.sme_outreach_records r
         where r.prospect_id=p.id order by r.contacted_at desc limit 1) o on true
     where p.archived_at is null
       and (not v_scoped or p.assigned_consultant_id = v_self)
       and (v_q is null or c.legal_name ilike '%'||v_q||'%'
            or coalesce(c.trading_name,'') ilike '%'||v_q||'%'
            or coalesce(l.address,'') ilike '%'||v_q||'%')
       and (jsonb_array_length(coalesce(p_filters->'planning_areas','[]'::jsonb))=0
            or l.planning_area in (select jsonb_array_elements_text(p_filters->'planning_areas')))
       and (jsonb_array_length(coalesce(p_filters->'districts','[]'::jsonb))=0
            or l.district in (select jsonb_array_elements_text(p_filters->'districts')))
       and (nullif(p_filters->>'postal_prefix','') is null
            or coalesce(l.postal_code,'') like (p_filters->>'postal_prefix')||'%')
       and (p_filters->'bbox' is null or (
              l.latitude between (p_filters#>>'{bbox,south}')::double precision
                             and (p_filters#>>'{bbox,north}')::double precision
          and l.longitude between (p_filters#>>'{bbox,west}')::double precision
                              and (p_filters#>>'{bbox,east}')::double precision))
       -- Radius: indexed bounding-box prefilter first, exact haversine second.
       and (v_lat is null or v_km is null or (
              l.latitude between v_lat-(v_km/111.0) and v_lat+(v_km/111.0)
          and l.longitude between v_lng-(v_km/(111.0*cos(radians(v_lat))))
                              and v_lng+(v_km/(111.0*cos(radians(v_lat))))
          and app.v297_haversine_km(v_lat,v_lng,l.latitude,l.longitude) <= v_km))
       and (jsonb_array_length(coalesce(p_filters->'sectors','[]'::jsonb))=0
            or exists (select 1 from public.sme_company_categories cc
                         join public.sme_categories cat on cat.id=cc.category_id
                         join public.sme_sectors sec on sec.id=cat.sector_id
                        where cc.company_id=c.id
                          and sec.sector_key in (select jsonb_array_elements_text(p_filters->'sectors'))))
       and (jsonb_array_length(coalesce(p_filters->'categories','[]'::jsonb))=0
            or exists (select 1 from public.sme_company_categories cc
                         join public.sme_categories cat on cat.id=cc.category_id
                        where cc.company_id=c.id
                          and cat.category_key in (select jsonb_array_elements_text(p_filters->'categories'))))
       and (nullif(p_filters->>'rating_min','') is null
            or coalesce(f.rating,0) >= (p_filters->>'rating_min')::numeric)
       and (nullif(p_filters->>'review_min','') is null
            or coalesce(f.review_count,0) >= (p_filters->>'review_min')::integer)
       and (nullif(p_filters->>'business_status','') is null
            or coalesce(f.business_status,'OPERATIONAL') = p_filters->>'business_status')
       and (jsonb_array_length(coalesce(p_filters->'price_levels','[]'::jsonb))=0
            or f.price_level::text in (select jsonb_array_elements_text(p_filters->'price_levels')))
       and (coalesce((p_filters->>'has_phone')::boolean,false)=false
            or coalesce(nullif(btrim(c.phone),''), f.provider_phone) is not null)
       and (coalesce((p_filters->>'has_website')::boolean,false)=false
            or coalesce(nullif(btrim(c.website),''), f.provider_website) is not null)
       and (coalesce((p_filters->>'has_email')::boolean,false)=false
            or nullif(btrim(coalesce(c.email,'')),'') is not null)
       and (coalesce((p_filters->>'has_whatsapp')::boolean,false)=false
            or exists (select 1 from public.sme_prospect_contacts ct
                        where ct.prospect_id=p.id and ct.active
                          and nullif(btrim(coalesce(ct.whatsapp_number,'')),'') is not null))
       and (nullif(p_filters->>'outreach','') is null or (
             case p_filters->>'outreach'
               when 'not_contacted' then o.contacted_at is null
               when 'contacted' then o.contacted_at is not null
               when 'follow_up' then o.outcome='follow_up'
               when 'interested' then o.outcome='interested'
               when 'not_interested' then o.outcome='not_interested'
               when 'do_not_contact' then o.outcome='do_not_contact'
               when 'converted' then p.converted_business_id is not null
               else true end))
       and (nullif(p_filters->>'contacted_within_days','') is null
            or o.contacted_at >= now() - ((p_filters->>'contacted_within_days')||' days')::interval)
       and (nullif(p_filters->>'follow_up','') is null or (
             case p_filters->>'follow_up'
               when 'due_today' then o.next_follow_up_at is not null
                 and (o.next_follow_up_at at time zone 'Asia/Singapore')::date
                     <= (now() at time zone 'Asia/Singapore')::date
               when 'overdue' then o.next_follow_up_at is not null and o.next_follow_up_at < now()
               else true end))
       and (nullif(p_filters->>'assigned_to','') is null
            or (p_filters->>'assigned_to'='unassigned' and p.assigned_consultant_id is null)
            or p.assigned_consultant_id::text = p_filters->>'assigned_to')
       and (nullif(p_filters->>'merchant_status','') is null or (
             case p_filters->>'merchant_status'
               when 'not_merchant' then p.converted_business_id is null
               when 'active' then p.converted_business_id is not null
               when 'onboarding' then p.current_stage_key in ('account_created','onboarding')
               when 'prospect' then p.converted_business_id is null and p.current_stage_key<>'lost'
               else true end))
       and (jsonb_array_length(coalesce(p_filters->'stage_keys','[]'::jsonb))=0
            or p.current_stage_key in (select jsonb_array_elements_text(p_filters->'stage_keys')))
       and (nullif(p_filters->>'score_min','') is null
            or coalesce(sc.score,0) >= (p_filters->>'score_min')::integer)
  ), agg as (
    select count(*) as total, count(*) filter (where latitude is not null) as mapped from hits
  )
  select case when p_mode='markers' then
    jsonb_build_object('mode','markers','total',(select total from agg),
      'mapped',(select mapped from agg),
      'capped',(select mapped from agg) > v_marker_cap,
      'marker_cap',v_marker_cap,
      'markers', coalesce((select jsonb_agg(jsonb_build_object(
          'prospect_id',m.prospect_id,'name',m.name,'lat',m.latitude,'lng',m.longitude,
          'score',m.score,'rating',m.rating,'contacted',m.last_contacted_at is not null,
          'converted',m.converted_business_id is not null))
        from (select * from hits where latitude is not null
               order by score desc limit v_marker_cap) m),'[]'::jsonb))
  else
    jsonb_build_object('mode','list','total',(select total from agg),
      'limit',p_limit,'offset',p_offset,
      'has_more',(select total from agg) > p_offset + p_limit,
      'rows', coalesce((select jsonb_agg(to_jsonb(r))
        from (select * from hits order by score desc, name
               limit p_limit offset p_offset) r),'[]'::jsonb))
  end into v_result;
  return v_result;
end $fn$;

create or replace function public.platform_crm_prospecting_detail_v297(p_prospect uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare v_row record; v_scoped boolean; v_self uuid;
begin
  perform app.v297_assert_prospecting('r');
  v_scoped := app.v89_platform_role()='sales_staff' and not app.is_super_admin();
  v_self := app.v226_self_consultant();
  select p.*, c.legal_name, c.trading_name, c.phone, c.website, c.email, c.registration_number
    into v_row
    from public.sme_prospects p join public.sme_companies c on c.id=p.company_id
   where p.id=p_prospect;
  if not found then raise exception 'prospect_not_found' using errcode='22023'; end if;
  if v_scoped and v_row.assigned_consultant_id is distinct from v_self then
    raise exception 'prospect_outside_your_book' using errcode='42501';
  end if;

  return jsonb_build_object(
    'prospect', jsonb_build_object(
      'id',v_row.id,'stage_key',v_row.current_stage_key,'version',v_row.version,
      'assigned_consultant_id',v_row.assigned_consultant_id,
      'converted_business_id',v_row.converted_business_id,'converted_at',v_row.converted_at,
      'next_action_at',v_row.next_action_at),
    'business', jsonb_build_object(
      'company_id',v_row.company_id,
      'name',coalesce(nullif(btrim(v_row.trading_name),''),v_row.legal_name),
      'legal_name',v_row.legal_name,'phone',v_row.phone,'website',v_row.website,
      'email',v_row.email,'registration_number',v_row.registration_number),
    'location', coalesce((select to_jsonb(l) from public.sme_company_locations l
                           where l.company_id=v_row.company_id and l.is_primary),'{}'::jsonb),
    'market', coalesce((select to_jsonb(f) from public.sme_company_market_facts f
                         where f.company_id=v_row.company_id),'{}'::jsonb),
    'sources', coalesce((select jsonb_agg(jsonb_build_object(
        'source',s.source,'source_id',s.source_id,'source_url',s.source_url,
        'last_synced_at',s.last_synced_at) order by s.last_synced_at desc)
      from public.sme_company_sources s where s.company_id=v_row.company_id),'[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'key',cat.category_key,'label',cat.label,'sector',sec.sector_key,'primary',cc.is_primary))
      from public.sme_company_categories cc
      join public.sme_categories cat on cat.id=cc.category_id
      join public.sme_sectors sec on sec.id=cat.sector_id
      where cc.company_id=v_row.company_id),'[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object(
        'id',ct.id,'name',ct.full_name,'role',ct.title,'phone',ct.phone,
        'whatsapp',ct.whatsapp_number,'email',ct.email,'type',ct.contact_type,
        'is_primary',ct.is_primary) order by ct.is_primary desc, ct.full_name)
      from public.sme_prospect_contacts ct
      where ct.prospect_id=p_prospect and ct.active),'[]'::jsonb),
    'outreach', coalesce((select jsonb_agg(jsonb_build_object(
        'id',r.id,'channel',r.channel,'outcome',r.outcome,'notes',r.notes,
        'contacted_at',r.contacted_at,'next_follow_up_at',r.next_follow_up_at,
        'consultant',k.display_name) order by r.contacted_at desc)
      from public.sme_outreach_records r
      left join public.platform_consultants k on k.id=r.consultant_id
      where r.prospect_id=p_prospect),'[]'::jsonb),
    'lead_score', coalesce((select jsonb_build_object('score',sc.score,
        'breakdown',sc.score_breakdown,'computed_at',sc.computed_at)
      from public.sme_lead_scores sc where sc.prospect_id=p_prospect),
      app.v297_lead_score(p_prospect)),
    'can_write', app.v297_can_prospecting('rw'),
    'can_assign', app.is_super_admin()
  );
end $fn$;

-- Logging outreach also creates the follow-up in the EXISTING sme_prospect_tasks
-- table, so a follow-up booked from the map appears in the CRM's existing task
-- surfaces rather than becoming a second, invisible to-do list.
create or replace function public.platform_crm_log_outreach_v297(
  p_prospect uuid, p_channel text, p_outcome text,
  p_notes text default null, p_contact uuid default null,
  p_next_follow_up_at timestamptz default null,
  p_idempotency_key text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare v_self uuid; v_scoped boolean; v_assigned uuid; v_id uuid; v_existing uuid;
begin
  perform app.v297_assert_prospecting('rw');
  v_scoped := app.v89_platform_role()='sales_staff' and not app.is_super_admin();
  v_self := app.v226_self_consultant();
  select assigned_consultant_id into v_assigned from public.sme_prospects where id=p_prospect;
  if not found then raise exception 'prospect_not_found' using errcode='22023'; end if;
  if v_scoped and v_assigned is distinct from v_self then
    raise exception 'prospect_outside_your_book' using errcode='42501';
  end if;
  if p_outcome='follow_up' and p_next_follow_up_at is null then
    raise exception 'follow_up_requires_a_date' using errcode='22023';
  end if;
  if p_next_follow_up_at is not null and p_next_follow_up_at < now() - interval '1 day' then
    raise exception 'follow_up_cannot_be_in_the_past' using errcode='22023';
  end if;

  -- A double-tap on Log contact must not create two records.
  if p_idempotency_key is not null then
    select id into v_existing from public.sme_outreach_records
     where prospect_id=p_prospect and created_by=auth.uid()
       and notes is not distinct from p_notes and channel=p_channel and outcome=p_outcome
       and created_at > now() - interval '2 minutes' limit 1;
    if found then return jsonb_build_object('outreach_id',v_existing,'replayed',true); end if;
  end if;

  insert into public.sme_outreach_records(
    prospect_id, contact_id, consultant_id, channel, outcome, notes,
    next_follow_up_at, created_by)
  values (p_prospect, p_contact, coalesce(v_self, v_assigned), p_channel, p_outcome,
          nullif(btrim(coalesce(p_notes,'')),''), p_next_follow_up_at, auth.uid())
  returning id into v_id;

  if p_next_follow_up_at is not null then
    insert into public.sme_prospect_tasks(
      prospect_id, title, due_at, assigned_consultant_id, status, created_by)
    values (p_prospect, 'Follow up: '||p_outcome, p_next_follow_up_at,
            coalesce(v_self, v_assigned), 'open', auth.uid());
    update public.sme_prospects set next_action_at=p_next_follow_up_at, updated_at=now()
     where id=p_prospect;
  end if;

  perform app.v297_refresh_lead_score(p_prospect);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'CRM_OUTREACH_LOGGED_V297','sme_prospects',p_prospect,
          jsonb_build_object('channel',p_channel,'outcome',p_outcome,
                             'follow_up',p_next_follow_up_at));
  return jsonb_build_object('outreach_id',v_id,'replayed',false,
    'lead_score',(select score from public.sme_lead_scores where prospect_id=p_prospect));
end $fn$;

create or replace function public.platform_crm_saved_filters_v297()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
begin
  perform app.v297_assert_prospecting('r');
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'filter_config',s.filter_config,'updated_at',s.updated_at)
      order by s.updated_at desc)
    from public.sme_saved_filters s where s.user_id=auth.uid()),'[]'::jsonb);
end $fn$;

create or replace function public.platform_crm_save_filter_v297(
  p_name text, p_config jsonb, p_id uuid default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare v_id uuid;
begin
  perform app.v297_assert_prospecting('r');
  if length(btrim(coalesce(p_name,''))) not between 1 and 80 then
    raise exception 'filter_name_required' using errcode='22023';
  end if;
  if p_id is not null then
    update public.sme_saved_filters
       set name=btrim(p_name), filter_config=coalesce(p_config,'{}'::jsonb), updated_at=now()
     where id=p_id and user_id=auth.uid() returning id into v_id;
    if v_id is null then raise exception 'filter_not_found' using errcode='22023'; end if;
  else
    insert into public.sme_saved_filters(user_id,name,filter_config)
    values (auth.uid(), btrim(p_name), coalesce(p_config,'{}'::jsonb))
    on conflict (user_id,name) do update
      set filter_config=excluded.filter_config, updated_at=now()
    returning id into v_id;
  end if;
  return jsonb_build_object('id',v_id);
end $fn$;

create or replace function public.platform_crm_delete_filter_v297(p_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare v_n integer;
begin
  perform app.v297_assert_prospecting('r');
  delete from public.sme_saved_filters where id=p_id and user_id=auth.uid();
  get diagnostics v_n = row_count;
  return jsonb_build_object('deleted',v_n);
end $fn$;

create or replace function public.platform_crm_prospecting_summary_v297()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare v_scoped boolean; v_self uuid;
begin
  perform app.v297_assert_prospecting('r');
  v_scoped := app.v89_platform_role()='sales_staff' and not app.is_super_admin();
  v_self := app.v226_self_consultant();
  return (
    with base as (
      select p.id, p.current_stage_key, p.converted_business_id, p.assigned_consultant_id,
             o.contacted_at, o.outcome, o.next_follow_up_at, l.planning_area,
             (select sec.sector_key from public.sme_company_categories cc
                join public.sme_categories cat on cat.id=cc.category_id
                join public.sme_sectors sec on sec.id=cat.sector_id
               where cc.company_id=p.company_id limit 1) as sector_key
        from public.sme_prospects p
        left join public.sme_company_locations l on l.company_id=p.company_id and l.is_primary
        left join lateral (select r.contacted_at,r.outcome,r.next_follow_up_at
                             from public.sme_outreach_records r
                            where r.prospect_id=p.id order by r.contacted_at desc limit 1) o on true
       where p.archived_at is null
         and (not v_scoped or p.assigned_consultant_id = v_self)
    )
    select jsonb_build_object(
      'total',(select count(*) from base),
      'uncontacted',(select count(*) from base where contacted_at is null),
      'contacted',(select count(*) from base where contacted_at is not null),
      'interested',(select count(*) from base where outcome='interested'),
      'not_interested',(select count(*) from base where outcome='not_interested'),
      'converted',(select count(*) from base where converted_business_id is not null),
      'follow_up_due',(select count(*) from base where next_follow_up_at is not null
         and (next_follow_up_at at time zone 'Asia/Singapore')::date
             <= (now() at time zone 'Asia/Singapore')::date),
      'follow_up_overdue',(select count(*) from base where next_follow_up_at < now()),
      'unassigned',(select count(*) from base where assigned_consultant_id is null),
      'by_sector',coalesce((select jsonb_agg(jsonb_build_object('key',sector_key,'count',n)
         order by n desc) from (select sector_key,count(*) n from base
           where sector_key is not null group by sector_key) s),'[]'::jsonb),
      'by_area',coalesce((select jsonb_agg(jsonb_build_object('name',planning_area,'count',n)
         order by n desc) from (select planning_area,count(*) n from base
           where planning_area is not null group by planning_area limit 12) a),'[]'::jsonb),
      'pipeline',coalesce((select jsonb_agg(jsonb_build_object(
           'key',st.stage_key,'label',st.label,'count',
           (select count(*) from base b where b.current_stage_key=st.stage_key))
         order by st.sort_order) from public.sme_pipeline_stages st),'[]'::jsonb)
    ));
end $fn$;

-- Provider ingest. The edge function normalizes whatever the provider returned into
-- a neutral shape; the DATABASE owns dedup and persistence so the rule holds no
-- matter which provider is wired up later.
--
-- Dedup contract: sme_company_sources UNIQUE(source, source_id). A place already
-- seen refreshes provider-owned facts ONLY and is reported as 'existing' — it never
-- creates a second company and never writes sme_companies, so a re-sync physically
-- cannot clobber a curated name, phone or website.
create or replace function public.platform_crm_ingest_discovered_v297(
  p_places jsonb,
  p_request jsonb default '{}'::jsonb,
  p_commit boolean default false,
  p_search_calls integer default 0,
  p_detail_calls integer default 0
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $fn$
declare
  v_place jsonb; v_run uuid; v_company uuid; v_prospect uuid; v_category uuid;
  v_found integer := 0; v_new integer := 0; v_existing integer := 0;
  v_source text; v_source_id text; v_name text;
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
      company_id,country,planning_area,district,address,postal_code,latitude,longitude,is_primary)
    values (v_company, coalesce(nullif(v_place->>'country',''),'SG'),
            nullif(v_place->>'planning_area',''), nullif(v_place->>'district',''),
            nullif(v_place->>'address',''), nullif(v_place->>'postal_code',''),
            nullif(v_place->>'latitude','')::double precision,
            nullif(v_place->>'longitude','')::double precision, true);

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
end $fn$;

revoke all on function public.platform_crm_prospecting_taxonomy_v297() from public, anon;
grant execute on function public.platform_crm_prospecting_taxonomy_v297() to authenticated;
revoke all on function public.platform_crm_prospecting_search_v297(jsonb,text,integer,integer) from public, anon;
grant execute on function public.platform_crm_prospecting_search_v297(jsonb,text,integer,integer) to authenticated;
revoke all on function public.platform_crm_prospecting_detail_v297(uuid) from public, anon;
grant execute on function public.platform_crm_prospecting_detail_v297(uuid) to authenticated;
revoke all on function public.platform_crm_log_outreach_v297(uuid,text,text,text,uuid,timestamptz,text) from public, anon;
grant execute on function public.platform_crm_log_outreach_v297(uuid,text,text,text,uuid,timestamptz,text) to authenticated;
revoke all on function public.platform_crm_saved_filters_v297() from public, anon;
grant execute on function public.platform_crm_saved_filters_v297() to authenticated;
revoke all on function public.platform_crm_save_filter_v297(text,jsonb,uuid) from public, anon;
grant execute on function public.platform_crm_save_filter_v297(text,jsonb,uuid) to authenticated;
revoke all on function public.platform_crm_delete_filter_v297(uuid) from public, anon;
grant execute on function public.platform_crm_delete_filter_v297(uuid) to authenticated;
revoke all on function public.platform_crm_prospecting_summary_v297() from public, anon;
grant execute on function public.platform_crm_prospecting_summary_v297() to authenticated;
revoke all on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) from public, anon;
grant execute on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) to authenticated;

commit;
