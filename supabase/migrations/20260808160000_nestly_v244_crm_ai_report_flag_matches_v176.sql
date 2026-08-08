-- NESTLY v244 — can_request_ai_report must mean what v176 will actually accept.
--
-- v226 set the CRM card's can_request_ai_report to simply "this prospect has a
-- converted business". That is not the condition
-- platform_request_ai_firm_report_v176 enforces. That function also refuses a
-- demo or synthetic firm outright:
--
--   if v_business.is_demo or v_business.is_synthetic then
--     raise exception 'ai_firm_reports_exclude_demo_firms' using errcode='22023';
--
-- So a converted DEMO firm was offered a "Generate AI report" button that could
-- only ever fail. A flag named can_request_ai_report has one job — to be true
-- exactly when the request will be accepted — and it was not doing it.
--
-- The flag now carries the same exclusion. The console renders the action
-- straight from the flag, so the two cannot drift: whoever changes the rule in
-- v176 has one place here to change with it.
--
-- Nothing else about v226 changes; this is a narrowing of one boolean.

begin;

create or replace function public.platform_crm_pipeline_v226(
  p_search text default null,
  p_stage text default null,
  p_consultant uuid default null,
  p_limit integer default 100,
  p_before timestamptz default null
) returns jsonb language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,100),1),250);
  v_role text := app.v89_platform_role();
  v_scope text;
  v_self uuid;
  v_filter uuid;
  v_unlinked boolean := false;
  v_items jsonb; v_before timestamptz; v_total bigint;
begin
  if auth.uid() is null or v_role is null then
    raise exception 'platform access is required' using errcode='42501';
  end if;
  if not app.v89_platform_can('onboarding','r') then
    raise exception 'CRM access is required' using errcode='42501';
  end if;
  if p_stage is not null and p_stage <> 'unmapped'
     and not exists(select 1 from public.sme_pipeline_stages where stage_key = p_stage) then
    raise exception 'unknown SME stage' using errcode='22023';
  end if;

  if v_role = 'sales_staff' then
    v_scope := 'own';
    v_self := app.v226_self_consultant();
    if p_consultant is not null and p_consultant is distinct from v_self then
      raise exception 'a consultant may only read their own assigned firms'
        using errcode='42501';
    end if;
    v_filter := v_self;
    v_unlinked := v_self is null;
  else
    v_scope := 'all';
    v_filter := p_consultant;
  end if;

  if v_scope = 'own' and v_unlinked then
    return jsonb_build_object(
      'items','[]'::jsonb,'next_before',null,'total_count',0,
      'scope',v_scope,'role',v_role,'consultant',null,
      'consultant_unlinked',true,
      'stages',(select coalesce(jsonb_agg(jsonb_build_object(
          'stage_key',stage_key,'n',0) order by sort_order),'[]'::jsonb)
        from public.sme_pipeline_stages),
      'consultants','[]'::jsonb);
  end if;

  with scoped as (
    select prospect.id, prospect.updated_at, prospect.current_stage_key
      from public.sme_prospects prospect
      join public.sme_companies company on company.id = prospect.company_id
     where prospect.archived_at is null
       and (v_filter is null or prospect.assigned_consultant_id = v_filter)
       and app.sme_prospect_search_match_v76(prospect.id, p_search)
  ), staged as (
    select * from scoped
     where (p_stage is null
            or (p_stage = 'unmapped' and current_stage_key is null)
            or current_stage_key = p_stage)
  ), page as (
    select * from staged
     where (p_before is null or updated_at < p_before)
     order by updated_at desc
     limit v_limit
  )
  select
    coalesce((select jsonb_agg(
       app.sme_prospect_card_v76(page.id) || jsonb_build_object(
         -- Same rule as platform_request_ai_firm_report_v176: converted, and
         -- neither demo nor synthetic. A demo firm asking for a report is
         -- refused there with 22023, so it must not be offered here.
         'can_request_ai_report',
         (select business.id is not null
                 and not coalesce(business.is_demo,false)
                 and not coalesce(business.is_synthetic,false)
            from public.sme_prospects prospect
            left join public.businesses business
              on business.id = prospect.converted_business_id
           where prospect.id = page.id))
       order by page.updated_at desc) from page),'[]'::jsonb),
    (select min(updated_at) from page),
    (select count(*) from staged)
  into v_items, v_before, v_total;

  return jsonb_build_object(
    'items', v_items,
    'next_before', v_before,
    'total_count', v_total,
    'has_more', v_total > jsonb_array_length(v_items),
    'scope', v_scope,
    'role', v_role,
    'consultant', v_filter,
    'consultant_unlinked', false,
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
        'stage_key', stage.stage_key, 'label', stage.label,
        'n', (select count(*) from public.sme_prospects prospect
               where prospect.archived_at is null
                 and prospect.current_stage_key = stage.stage_key
                 and (v_filter is null or prospect.assigned_consultant_id = v_filter)
                 and app.sme_prospect_search_match_v76(prospect.id, p_search)))
        order by stage.sort_order) from public.sme_pipeline_stages stage),'[]'::jsonb),
    'consultants', case when v_scope = 'all' then coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', consultant.id,'display_name', consultant.display_name,
          'n', (select count(*) from public.sme_prospects prospect
                 where prospect.archived_at is null
                   and prospect.assigned_consultant_id = consultant.id))
          order by consultant.display_name)
        from public.platform_consultants consultant
       where consultant.active),'[]'::jsonb)
      else '[]'::jsonb end);
end $$;

revoke all on function public.platform_crm_pipeline_v226(text,text,uuid,integer,timestamptz)
  from public, anon, authenticated;
grant execute on function public.platform_crm_pipeline_v226(text,text,uuid,integer,timestamptz)
  to authenticated;

commit;
