-- Rollback-only v195 acceptance: a merge must never try to move immutable
-- source lineage. The v185 fixture had no lineage rows, so this suite creates
-- them on both records on purpose — that omission is what broke the first
-- real production merge with 23001.
begin;

do $v195$
declare
  v_sa uuid; v_co uuid; v_src uuid; v_tgt uuid; v_res jsonb; v_n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.sme_companies(legal_name) values ('V195 Fixture') returning id into v_co;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_src;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_tgt;
  insert into public.sme_prospect_source_lineage(prospect_id,source_system,source_type,created_by)
    values (v_src,'import_batch_a','import',v_sa),
           (v_tgt,'website','website',v_sa);
  insert into public.sme_prospect_contacts(prospect_id,full_name,email,is_primary)
    values (v_src,'Same Person','dupe@example.com',true),
           (v_tgt,'Same Person','dupe@example.com',true);

  -- Before v195 this raised 23001 from app.v75_immutable_guard.
  v_res := public.platform_merge_prospects_v184(v_src,v_tgt,'same firm, both carry lineage');
  if v_res->>'status' <> 'merged' then raise exception 'A: %', v_res; end if;
  if (v_res#>>'{moved,source_lineage_retained}')::int <> 1 then
    raise exception 'B: expected 1 lineage row retained, got %', v_res->'moved';
  end if;

  -- Provenance stays with the record it describes, in both directions.
  select count(*) into v_n from public.sme_prospect_source_lineage
   where prospect_id=v_src and source_system='import_batch_a';
  if v_n <> 1 then raise exception 'C: source lineage left its own record'; end if;
  select count(*) into v_n from public.sme_prospect_source_lineage where prospect_id=v_tgt;
  if v_n <> 1 then raise exception 'D: survivor inherited lineage it never had, got %', v_n; end if;
  select count(*) into v_n from public.sme_prospect_source_lineage
   where prospect_id=v_tgt and source_system='website';
  if v_n <> 1 then raise exception 'E: survivor lost its own lineage'; end if;

  raise notice 'v195 merge keeps source lineage: all assertions passed';
end
$v195$;

rollback;
