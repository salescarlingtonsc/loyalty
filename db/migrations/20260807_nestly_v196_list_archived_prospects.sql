-- NESTLY v196 — you can archive a firm record, so you must be able to find it
-- again.
--
-- v185 gave the CRM its exit doors and v184's read filters hid archived records
-- from the board, the list, the directory and every count. That was the point,
-- but it left restore unreachable: platform_restore_prospect_v184 exists and
-- works, and there was no way to learn the id of anything to pass it. An
-- archive you cannot inspect is indistinguishable from a delete, which is
-- exactly what the soft-delete design set out to avoid.
--
-- This adds the one missing read. It is deliberately its own RPC rather than a
-- flag on the live list: the live contracts stay archived-free by construction,
-- so no existing caller can accidentally surface an archived firm.
--
-- Rows carry why they left and where they went, so the console can explain a
-- record's fate without a second lookup, and can hide Restore on the ones that
-- were merged away (those cannot be restored on their own).

begin;

create or replace function public.platform_list_archived_prospects_v196(
  p_search text default null,
  p_limit integer default 50
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();
  v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);
  v_search text:=nullif(btrim(coalesce(p_search,'')),'');
  v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;

  select jsonb_build_object(
    'items',coalesce((
      select jsonb_agg(row_payload order by row_payload->>'archived_at' desc)
      from (
        select jsonb_build_object(
          'id',prospect.id,
          'company_name',coalesce(company.trading_name,company.legal_name),
          'registration_number',company.registration_number,
          'stage_key',prospect.current_stage_key,
          'archived_at',prospect.archived_at,
          'archive_reason',prospect.archive_reason,
          'archived_by_name',coalesce(consultant.display_name,'Super admin'),
          'merged_into_prospect_id',prospect.merged_into_prospect_id,
          'merged_into_name',survivor_company.legal_name,
          -- A merged-away record cannot be restored on its own; the console
          -- uses this to show "Merged" instead of a Restore button.
          'restorable',prospect.merged_into_prospect_id is null,
          'contacts',(select count(*) from public.sme_prospect_contacts contact
                       where contact.prospect_id=prospect.id)
        ) as row_payload
        from public.sme_prospects prospect
        join public.sme_companies company on company.id=prospect.company_id
        left join public.platform_consultants consultant
          on consultant.user_id=prospect.archived_by
        left join public.sme_prospects survivor
          on survivor.id=prospect.merged_into_prospect_id
        left join public.sme_companies survivor_company
          on survivor_company.id=survivor.company_id
        where prospect.archived_at is not null
          and (v_search is null
            or lower(concat_ws(' ',company.legal_name,company.trading_name,
                 company.registration_number,prospect.archive_reason))
                like '%'||lower(v_search)||'%')
        order by prospect.archived_at desc
        limit v_limit
      ) rows
    ),'[]'::jsonb),
    'total_count',(select count(*) from public.sme_prospects
                    where archived_at is not null),
    'truncated',(select count(*) from public.sme_prospects
                  where archived_at is not null) > v_limit
  ) into v_result;

  insert into public.audit_log(business_id,actor,action,entity,detail)
  values(null,v_actor,'PLATFORM_ARCHIVED_PROSPECTS_READ_V196','sme_prospects',
    jsonb_build_object('search',v_search,'limit',v_limit,
      'result_count',jsonb_array_length(v_result->'items')));
  return v_result;
end $$;

revoke all on function public.platform_list_archived_prospects_v196(text,integer)
  from public, anon, authenticated;
grant execute on function public.platform_list_archived_prospects_v196(text,integer)
  to authenticated;

commit;
