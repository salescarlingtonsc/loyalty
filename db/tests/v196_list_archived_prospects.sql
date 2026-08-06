-- Rollback-only v196 acceptance: an archived record must remain findable, or
-- the soft delete is indistinguishable from a hard one.
begin;

do $v196$
declare
  v_sa uuid; v_co uuid; v_kept uuid; v_merged uuid; v_plain uuid;
  v_res jsonb; v_row jsonb; v_n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.sme_companies(legal_name) values ('V196 Kept') returning id into v_co;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_kept;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_merged;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_plain;
  insert into public.sme_prospect_contacts(prospect_id,full_name,email,is_primary)
    values (v_merged,'Merged Person','merged@example.com',true),
           (v_plain,'Plain Person','plain@example.com',true);

  perform public.platform_merge_prospects_v184(v_merged,v_kept,'v196 fixture merge');
  perform public.platform_archive_prospect_v184(v_plain,'v196 fixture archive');

  v_res := public.platform_list_archived_prospects_v196(null,50);
  if (v_res->>'total_count')::int < 2 then
    raise exception 'A: both archived records must be listed, got %', v_res->>'total_count';
  end if;

  -- A plainly archived record is restorable.
  select value into v_row from jsonb_array_elements(v_res->'items') value
   where value->>'id' = v_plain::text;
  if v_row is null then raise exception 'B: archived record missing from the list'; end if;
  if (v_row->>'restorable')::boolean is not true then
    raise exception 'C: a plainly archived record must be restorable';
  end if;
  if v_row->>'archive_reason' is null then raise exception 'D: reason not surfaced'; end if;

  -- A merged-away record is listed but must NOT offer restore.
  select value into v_row from jsonb_array_elements(v_res->'items') value
   where value->>'id' = v_merged::text;
  if v_row is null then raise exception 'E: merged-away record missing from the list'; end if;
  if (v_row->>'restorable')::boolean is not false then
    raise exception 'F: a merged-away record must not be restorable';
  end if;
  if v_row->>'merged_into_prospect_id' is null then
    raise exception 'G: merge destination not surfaced';
  end if;

  -- Restore actually returns the record to the live board.
  perform public.platform_restore_prospect_v184(v_plain,'v196 fixture restore');
  select count(*) into v_n from app.platform_firm_rows_v88(now()) where prospect_id=v_plain;
  if v_n <> 1 then raise exception 'H: restored record did not return to the board'; end if;
  select count(*) into v_n from jsonb_array_elements(
    (public.platform_list_archived_prospects_v196(null,50))->'items') value
   where value->>'id' = v_plain::text;
  if v_n <> 0 then raise exception 'I: restored record still listed as archived'; end if;

  -- Search narrows; a miss is an empty contract, not an error.
  if jsonb_array_length((public.platform_list_archived_prospects_v196('zzz-no-match',50))->'items') <> 0 then
    raise exception 'J: a search miss returned rows';
  end if;

  raise notice 'v196 archived-record listing: all assertions passed';
end
$v196$;

rollback;
