-- nestly_v314_business_explorer_and_funnel
--
-- This is the read/act surface for the conversion-first prospecting system
-- (v297-v299, v311). Two things are deliberate:
--
--   1. There is NO lead scoring anywhere in this file. The explorer
--      (platform_explorer_search_v312) sorts and filters the raw facts
--      already captured about a prospect -- name, location, category,
--      contact/outreach history, assignment, stage -- it does not compute or
--      surface any predictive or weighted "likely to convert" score.
--   2. The funnel (platform_conversion_funnel_v312) MEASURES conversion from
--      real stage history (sme_prospect_stage_history timestamps per stage)
--      rather than predicting it. Every number in its output is a count or
--      rate derived from what actually happened to real prospects, not a
--      model's guess about what might happen.
--
-- platform_explorer_bulk_assign_v312 is super-admin only, per the owner's
-- standing rule that prospect-to-consultant assignment is a platform
-- operation, not a firm-level one. It also refuses to assign any business
-- that is already a Peekaa merchant (peekaa_business_id / converted_business_id
-- set) -- a converted business has left the prospecting pool and must not be
-- handed to a rep as if it were still a lead.
--
-- platform_merchant_matches_v312 / platform_decide_merchant_match_v312 round
-- out the admin review loop for candidate matches between a prospected
-- company and an existing Peekaa merchant account, so an accidental duplicate
-- import doesn't sit unresolved.

begin;

CREATE OR REPLACE FUNCTION public.platform_conversion_funnel_v312(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_from timestamptz; v_to timestamptz; d jsonb;
begin
  perform app.v297_assert_prospecting('r');
  v_from := coalesce(p_from, current_date - 3650)::timestamptz;
  v_to := coalesce(p_to, current_date)::timestamptz + interval '1 day';

  with scoped as (
    select p.id, p.company_id, p.assigned_consultant_id, p.created_at,
           p.converted_at, p.current_stage_key,
           (c.peekaa_business_id is not null or p.converted_business_id is not null) as is_merchant,
           l.planning_area,
           sec.label as industry, cat.label as subcategory,
           (select min(h.occurred_at) from public.sme_prospect_stage_history h
             where h.prospect_id=p.id and h.to_stage_key='contacted') as contacted_at,
           (select min(h.occurred_at) from public.sme_prospect_stage_history h
             where h.prospect_id=p.id and h.to_stage_key='interested') as interested_at,
           (select min(h.occurred_at) from public.sme_prospect_stage_history h
             where h.prospect_id=p.id and h.to_stage_key='appointment') as appointment_at,
           (select min(h.occurred_at) from public.sme_prospect_stage_history h
             where h.prospect_id=p.id and h.to_stage_key in ('onboarding','account_created')) as onboarding_at,
           (select count(*) from public.sme_outreach_records o where o.prospect_id=p.id) as touches
      from public.sme_prospects p
      join public.sme_companies c on c.id=p.company_id
      left join public.sme_company_locations l on l.company_id=c.id and l.is_primary
      left join public.sme_company_categories cc on cc.company_id=c.id and cc.is_primary
      left join public.sme_categories cat on cat.id=cc.category_id
      left join public.sme_sectors sec on sec.id=cat.sector_id
     where p.archived_at is null and p.created_at >= v_from and p.created_at < v_to
  )
  select jsonb_build_object(
    'funnel', jsonb_build_object(
      'businesses', count(*),
      'non_peekaa', count(*) filter (where not is_merchant),
      'assigned', count(*) filter (where assigned_consultant_id is not null),
      'contacted', count(*) filter (where contacted_at is not null),
      'interested', count(*) filter (where interested_at is not null),
      'appointments', count(*) filter (where appointment_at is not null),
      'onboarding', count(*) filter (where onboarding_at is not null),
      'merchants', count(*) filter (where is_merchant)),
    'rates', jsonb_build_object(
      'contact_to_appointment', case when count(*) filter (where contacted_at is not null) > 0
        then round(100.0 * count(*) filter (where appointment_at is not null)
                 / count(*) filter (where contacted_at is not null), 1) else null end,
      'appointment_to_onboarding', case when count(*) filter (where appointment_at is not null) > 0
        then round(100.0 * count(*) filter (where onboarding_at is not null)
                 / count(*) filter (where appointment_at is not null), 1) else null end,
      'overall', case when count(*) > 0
        then round(100.0 * count(*) filter (where is_merchant) / count(*), 1) else null end),
    'effort', jsonb_build_object(
      'touches_per_conversion', case when count(*) filter (where is_merchant) > 0
        then round(sum(touches)::numeric / count(*) filter (where is_merchant), 1) else null end,
      'avg_days_to_conversion', (select round(avg(extract(epoch from (converted_at - created_at))/86400)::numeric,1)
                                   from scoped where converted_at is not null)),
    'by_consultant', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('consultant_id', assigned_consultant_id,
          'assigned', count(*), 'contacted', count(*) filter (where contacted_at is not null),
          'appointments', count(*) filter (where appointment_at is not null),
          'merchants', count(*) filter (where is_merchant)) as x
        from scoped where assigned_consultant_id is not null
        group by assigned_consultant_id) t),'[]'::jsonb),
    'by_location', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('planning_area', planning_area, 'businesses', count(*),
          'contacted', count(*) filter (where contacted_at is not null),
          'merchants', count(*) filter (where is_merchant)) as x
        from scoped where planning_area is not null group by planning_area) t),'[]'::jsonb),
    'by_industry', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('industry', industry, 'businesses', count(*),
          'merchants', count(*) filter (where is_merchant)) as x
        from scoped where industry is not null group by industry) t),'[]'::jsonb),
    'by_category', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('category', subcategory, 'businesses', count(*),
          'merchants', count(*) filter (where is_merchant)) as x
        from scoped where subcategory is not null group by subcategory) t),'[]'::jsonb)
  ) into d from scoped;

  return coalesce(d, '{}'::jsonb);
end $function$;

revoke all on function public.platform_conversion_funnel_v312(date,date) from public, anon;
grant execute on function public.platform_conversion_funnel_v312(date,date) to authenticated;

CREATE OR REPLACE FUNCTION public.platform_decide_merchant_match_v312(p_match uuid, p_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_actor uuid := auth.uid(); m public.sme_merchant_match_candidates%rowtype;
begin
  perform app.v297_assert_prospecting('rw');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'merchant match review requires admin' using errcode='42501';
  end if;
  select * into m from public.sme_merchant_match_candidates where id=p_match for update;
  if not found then raise exception 'match was not found' using errcode='22023'; end if;
  if m.status <> 'pending' then
    return jsonb_build_object('outcome','already_decided','status',m.status);
  end if;

  if p_confirm then
    update public.sme_companies
       set peekaa_business_id = m.business_id, merchant_linked_at = now(),
           merchant_link_basis = 'reviewed'
     where id = m.company_id;
  end if;

  update public.sme_merchant_match_candidates
     set status = case when p_confirm then 'confirmed' else 'rejected' end,
         decided_by = v_actor, decided_at = now()
   where id = p_match;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (m.business_id, v_actor, 'MERCHANT_MATCH_DECIDED_V312',
          'sme_merchant_match_candidates', p_match,
          jsonb_build_object('confirmed', p_confirm, 'company_id', m.company_id));

  return jsonb_build_object('outcome', case when p_confirm then 'linked' else 'rejected' end);
end $function$;

revoke all on function public.platform_decide_merchant_match_v312(uuid,boolean) from public, anon;
grant execute on function public.platform_decide_merchant_match_v312(uuid,boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.platform_explorer_bulk_assign_v312(p_prospects uuid[], p_consultant uuid, p_reason text DEFAULT 'Bulk assigned from the Business Explorer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_actor uuid := auth.uid(); v_assigned integer := 0; v_skipped integer := 0; v_id uuid;
begin
  perform app.v297_assert_prospecting('rw');
  if not app.is_super_admin() then
    raise exception 'only a super admin may assign prospects' using errcode='42501';
  end if;
  if p_prospects is null or cardinality(p_prospects) = 0 then
    raise exception 'no prospects were selected' using errcode='22023';
  end if;
  if cardinality(p_prospects) > 500 then
    raise exception 'assign at most 500 prospects at a time' using errcode='22023';
  end if;
  if p_consultant is null then
    raise exception 'a consultant is required' using errcode='22023';
  end if;

  foreach v_id in array p_prospects loop
    -- Never hand a rep a business that is already ours.
    update public.sme_prospects p
       set assigned_consultant_id = p_consultant,
           current_stage_key = case when p.current_stage_key='new_lead' then 'assigned'
                                    else p.current_stage_key end,
           stage_entered_at = case when p.current_stage_key='new_lead' then now()
                                   else p.stage_entered_at end,
           version = p.version + 1, updated_by = v_actor, updated_at = now()
      from public.sme_companies c
     where p.id = v_id and c.id = p.company_id
       and p.archived_at is null
       and p.converted_business_id is null and c.peekaa_business_id is null;
    if found then
      v_assigned := v_assigned + 1;
      insert into public.sme_prospect_assignments(prospect_id, consultant_id, assigned_by, reason)
      values (v_id, p_consultant, v_actor, p_reason);
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (null, v_actor, 'PROSPECTS_BULK_ASSIGNED_V312', 'sme_prospects', null,
          jsonb_build_object('consultant', p_consultant, 'requested', cardinality(p_prospects),
                             'assigned', v_assigned, 'skipped', v_skipped));

  return jsonb_build_object('assigned', v_assigned, 'skipped', v_skipped,
                            'requested', cardinality(p_prospects));
end $function$;

revoke all on function public.platform_explorer_bulk_assign_v312(uuid[],uuid,text) from public, anon;
grant execute on function public.platform_explorer_bulk_assign_v312(uuid[],uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION public.platform_explorer_search_v312(p_filters jsonb DEFAULT '{}'::jsonb, p_mode text DEFAULT 'list'::text, p_sort text DEFAULT 'added_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rows jsonb; v_total integer; v_self uuid; v_is_admin boolean;
begin
  perform app.v297_assert_prospecting('r');
  if p_mode not in ('list','markers','ids','count') then
    raise exception 'unknown explorer mode' using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'invalid_page_size' using errcode='22023';
  end if;
  if p_sort not in ('added_desc','added_asc','name_asc','name_desc','area_asc',
                    'category_asc','rating_desc','reviews_desc',
                    'contacted_desc','follow_up_asc') then
    raise exception 'unknown sort order' using errcode='22023';
  end if;

  v_is_admin := app.is_super_admin() or app.v89_platform_role() = 'admin';
  v_self := app.v226_self_consultant();

  with base as (
    select
      p.id as prospect_id, c.id as company_id,
      coalesce(c.trading_name, c.legal_name) as name,
      c.phone, c.website, c.email,
      l.planning_area, l.district, l.postal_code, l.address, l.latitude, l.longitude,
      f.rating, f.review_count, f.business_status, f.price_level,
      src.source_id as place_id, src.source_url,
      sec.label as industry, parent.label as category, cat.label as subcategory,
      cat.category_key,
      p.current_stage_key, st.label as stage_label, st.kind as stage_kind,
      p.assigned_consultant_id, p.created_at,
      -- A business is OURS if we converted it OR it matched a live merchant.
      -- Either way it must leave the prospecting pool.
      (c.peekaa_business_id is not null or p.converted_business_id is not null) as is_peekaa_merchant,
      coalesce(c.peekaa_business_id, p.converted_business_id) as merchant_id,
      (select max(o.contacted_at) from public.sme_outreach_records o where o.prospect_id=p.id) as last_contacted_at,
      (select min(t.due_at) from public.sme_prospect_tasks t
        where t.prospect_id=p.id and t.completed_at is null) as next_follow_up_at
      from public.sme_prospects p
      join public.sme_companies c on c.id = p.company_id
      left join public.sme_company_locations l on l.company_id=c.id and l.is_primary
      left join public.sme_company_market_facts f on f.company_id=c.id
      left join public.sme_company_sources src on src.company_id=c.id and src.source='google_places'
      left join public.sme_company_categories cc on cc.company_id=c.id and cc.is_primary
      left join public.sme_categories cat on cat.id=cc.category_id
      left join public.sme_categories parent on parent.id=cat.parent_category_id
      left join public.sme_sectors sec on sec.id=cat.sector_id
      left join public.sme_pipeline_stages st on st.stage_key=p.current_stage_key
     where p.archived_at is null
       and (v_is_admin or p.assigned_consultant_id = v_self)
  ),
  filtered as (
    select b.*, count(*) over() as total_count from base b
     where (nullif(p_filters->>'q','') is null
            or b.name ilike '%'||(p_filters->>'q')||'%'
            or coalesce(b.phone,'') ilike '%'||(p_filters->>'q')||'%'
            or coalesce(b.postal_code,'') ilike (p_filters->>'q')||'%')
       and (jsonb_array_length(coalesce(p_filters->'planning_areas','[]'::jsonb))=0
            or b.planning_area in (select jsonb_array_elements_text(p_filters->'planning_areas')))
       and (jsonb_array_length(coalesce(p_filters->'industries','[]'::jsonb))=0
            or b.industry in (select jsonb_array_elements_text(p_filters->'industries')))
       and (jsonb_array_length(coalesce(p_filters->'categories','[]'::jsonb))=0
            or b.category in (select jsonb_array_elements_text(p_filters->'categories')))
       and (jsonb_array_length(coalesce(p_filters->'subcategories','[]'::jsonb))=0
            or b.category_key in (select jsonb_array_elements_text(p_filters->'subcategories')))
       and (jsonb_array_length(coalesce(p_filters->'stage_keys','[]'::jsonb))=0
            or b.current_stage_key in (select jsonb_array_elements_text(p_filters->'stage_keys')))
       and (case coalesce(p_filters->>'peekaa_status','not_merchant')
              when 'not_merchant' then b.is_peekaa_merchant = false
              when 'merchant' then b.is_peekaa_merchant = true
              else true end)
       and (case coalesce(p_filters->>'assignment','all')
              when 'unassigned' then b.assigned_consultant_id is null
              when 'assigned' then b.assigned_consultant_id is not null
              else true end)
       and (nullif(p_filters->>'assigned_to','') is null
            or b.assigned_consultant_id = (p_filters->>'assigned_to')::uuid)
       and (case coalesce(p_filters->>'contact','all')
              when 'not_contacted' then b.last_contacted_at is null
              when 'contacted' then b.last_contacted_at is not null
              else true end)
       and (case coalesce(p_filters->>'follow_up','all')
              when 'overdue' then b.next_follow_up_at < now()
              when 'due_today' then b.next_follow_up_at::date = (now() at time zone 'Asia/Singapore')::date
              when 'scheduled' then b.next_follow_up_at is not null
              when 'none' then b.next_follow_up_at is null
              else true end)
       and (nullif(p_filters->>'business_status','') is null
            or b.business_status = p_filters->>'business_status')
       and (nullif(p_filters->>'rating_min','') is null
            or b.rating >= (p_filters->>'rating_min')::numeric)
       and (nullif(p_filters->>'review_min','') is null
            or b.review_count >= (p_filters->>'review_min')::integer)
       and (coalesce((p_filters->>'has_phone')::boolean,false) = false or b.phone is not null)
       and (coalesce((p_filters->>'has_website')::boolean,false) = false or b.website is not null)
       and (p_filters->'bbox' is null or (
             b.latitude between (p_filters#>>'{bbox,south}')::double precision
                            and (p_filters#>>'{bbox,north}')::double precision
         and b.longitude between (p_filters#>>'{bbox,west}')::double precision
                             and (p_filters#>>'{bbox,east}')::double precision))
  ),
  ordered as (
    select * from filtered
     order by
       case when p_sort='name_asc' then name end asc nulls last,
       case when p_sort='name_desc' then name end desc nulls last,
       case when p_sort='area_asc' then planning_area end asc nulls last,
       case when p_sort='category_asc' then subcategory end asc nulls last,
       case when p_sort='rating_desc' then rating end desc nulls last,
       case when p_sort='reviews_desc' then review_count end desc nulls last,
       case when p_sort='contacted_desc' then last_contacted_at end desc nulls last,
       case when p_sort='follow_up_asc' then next_follow_up_at end asc nulls last,
       case when p_sort='added_asc' then created_at end asc,
       case when p_sort='added_desc' then created_at end desc,
       name asc
     limit case when p_mode='ids' then 5000 when p_mode='count' then 1 else p_limit end
    offset case when p_mode in ('ids','count') then 0 else p_offset end
  )
  select
    coalesce(max(o.total_count)::integer, 0),
    case p_mode
      when 'count' then '[]'::jsonb
      when 'ids' then coalesce(jsonb_agg(to_jsonb(o.prospect_id)),'[]'::jsonb)
      when 'markers' then coalesce(jsonb_agg(jsonb_build_object(
        'prospect_id',o.prospect_id,'name',o.name,'lat',o.latitude,'lng',o.longitude,
        'is_peekaa_merchant',o.is_peekaa_merchant,
        'assigned',o.assigned_consultant_id is not null,
        'stage',o.current_stage_key)) filter (where o.latitude is not null),'[]'::jsonb)
      else coalesce(jsonb_agg(to_jsonb(o) - 'total_count'),'[]'::jsonb) end
  into v_total, v_rows
  from ordered o;

  return jsonb_build_object(
    'total', v_total, 'limit', p_limit, 'offset', p_offset,
    'sort', p_sort, 'mode', p_mode,
    case p_mode when 'ids' then 'ids' when 'markers' then 'markers' else 'rows' end, v_rows);
end $function$;

revoke all on function public.platform_explorer_search_v312(jsonb,text,text,integer,integer) from public, anon;
grant execute on function public.platform_explorer_search_v312(jsonb,text,text,integer,integer) to authenticated;

CREATE OR REPLACE FUNCTION public.platform_merchant_matches_v312(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  perform app.v297_assert_prospecting('r');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'merchant match review requires admin' using errcode='42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', m.id, 'company_id', m.company_id, 'business_id', m.business_id,
      'company_name', coalesce(c.trading_name, c.legal_name),
      'merchant_name', coalesce(b.legal_name, b.name),
      'company_postal', l.postal_code, 'merchant_postal', b.postal_code,
      'match_basis', m.match_basis, 'created_at', m.created_at))
    from public.sme_merchant_match_candidates m
    join public.sme_companies c on c.id=m.company_id
    join public.businesses b on b.id=m.business_id
    left join public.sme_company_locations l on l.company_id=c.id and l.is_primary
   where m.status='pending'
   order by m.created_at desc
   limit greatest(least(coalesce(p_limit,50),200),1)),'[]'::jsonb);
end $function$;

revoke all on function public.platform_merchant_matches_v312(integer) from public, anon;
grant execute on function public.platform_merchant_matches_v312(integer) to authenticated;

commit;
