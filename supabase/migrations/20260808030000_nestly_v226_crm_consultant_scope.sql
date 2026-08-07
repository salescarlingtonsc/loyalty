-- NESTLY v226 — CRM becomes a consultant-scoped module.
--
-- THE GAP THIS CLOSES
-- Every CRM read today goes through app.is_platform_operator_v75(), which
-- returns true only for a super admin or a grant with role='admin'. The
-- consultant role is 'sales_staff' — app.v89_platform_can() already admits it
-- to the 'onboarding' module, but is_platform_operator_v75() rejects it before
-- that check is ever reached. The result is not "a consultant sees too much",
-- it is "a consultant sees nothing": platform_list_prospects_v76 raises 42501
-- for them.
--
-- Worse, p_consultant on the v76 reader is a caller-supplied FILTER, not a
-- scope. If a consultant were simply let through that function, they would
-- read the entire pipeline by omitting the argument. Scope has to be decided
-- by the server from the caller's identity, never accepted from the client.
--
-- WHAT THIS ADDS
-- platform_crm_pipeline_v226 resolves the scope itself:
--   super admin / admin  -> the whole pipeline; p_consultant is an optional
--                           filter, and consultant facets are returned so the
--                           console can offer "filter by consultant".
--   sales_staff          -> their own book only. p_consultant is not a filter
--                           for them; passing someone else's id is refused
--                           (42501) rather than quietly re-scoped, because a
--                           silent re-scope teaches a caller that the id was
--                           wrong rather than forbidden.
--
-- Assignment is read from sme_prospects.assigned_consultant_id — the CURRENT
-- owner. sme_prospect_assignments is the history of how it got there and is
-- deliberately not used for scoping: a consultant who handed a firm over must
-- stop seeing it.
--
-- FAIL CLOSED: a sales_staff user with no active platform_consultants row is
-- linked to no book at all. That returns an empty pipeline with
-- consultant_unlinked=true, not every prospect and not an error — there is
-- nothing to show and nothing has gone wrong.
--
-- Consultant facets are withheld from a consultant. Their own totals are
-- theirs; the size and shape of everyone else's book is not.
--
-- AI reports are NOT re-implemented here. platform_request_ai_firm_report_v176
-- already gates on app.v176_is_assigned_consultant(), which is exactly this
-- module's rule expressed for a converted business. Each card carries
-- converted_business_id and can_request_ai_report so the console can offer the
-- action precisely where the v176 function will accept it.

begin;

-- Which consultant record, if any, is this login? Active only: a departed
-- consultant's login must not keep reading their old book.
create or replace function app.v226_self_consultant()
returns uuid language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select consultant.id
    from public.platform_consultants consultant
   where consultant.user_id = auth.uid()
     and consultant.active
   order by consultant.created_at, consultant.id
   limit 1
$$;

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
  v_scope text;            -- 'all' | 'own'
  v_self uuid;
  v_filter uuid;           -- the consultant actually applied to the query
  v_unlinked boolean := false;
  v_items jsonb; v_before timestamptz; v_total bigint;
begin
  if auth.uid() is null or v_role is null then
    raise exception 'platform access is required' using errcode='42501';
  end if;
  -- A super admin bypasses grants; everyone else needs the module.
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

  -- An unlinked consultant has an empty book. Returning here keeps the empty
  -- case from depending on "v_filter is null means no filter" below, which
  -- would hand them the entire pipeline.
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
         'can_request_ai_report',
         (select prospect.converted_business_id is not null
            from public.sme_prospects prospect where prospect.id = page.id))
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
    -- Stage facets are always the caller's OWN scope, so a consultant's board
    -- counts match the cards they can actually open.
    'stages', coalesce((select jsonb_agg(jsonb_build_object(
        'stage_key', stage.stage_key, 'label', stage.label,
        'n', (select count(*) from public.sme_prospects prospect
               where prospect.archived_at is null
                 and prospect.current_stage_key = stage.stage_key
                 and (v_filter is null or prospect.assigned_consultant_id = v_filter)
                 and app.sme_prospect_search_match_v76(prospect.id, p_search)))
        order by stage.sort_order) from public.sme_pipeline_stages stage),'[]'::jsonb),
    -- Only an all-scope operator may see who else holds a book.
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
