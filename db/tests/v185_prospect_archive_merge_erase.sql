-- Rollback-only v185 acceptance: the CRM's archive, merge and PDPA erasure
-- paths. Prod-compatible: every row is fixture-scoped and the transaction is
-- rolled back, so no live prospect is touched.
begin;

do $v185$
declare
  v_sa uuid; v_co uuid; v_src uuid; v_tgt uuid; v_solo uuid;
  v_contact uuid; v_res jsonb; v_n int; v_ok text:='';
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.sme_companies(legal_name) values ('V185 Fixture Co') returning id into v_co;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_src;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_tgt;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_solo;
  insert into public.sme_prospect_contacts(prospect_id,full_name,email,phone,is_primary)
    values (v_src,'Src Person','src@example.com','+6591000001',true) returning id into v_contact;
  insert into public.sme_prospect_contacts(prospect_id,full_name,email,phone,is_primary)
    values (v_tgt,'Tgt Person','tgt@example.com','+6591000002',true);

  select count(*) into v_n from app.platform_firm_rows_v88(now())
   where prospect_id in (v_src,v_tgt,v_solo);
  if v_n <> 3 then raise exception 'A: expected 3 on the board, got %', v_n; end if;

  -- A reason is mandatory for every destructive verb.
  begin
    perform public.platform_archive_prospect_v184(v_solo,'   ');
    raise exception 'B: blank archive reason accepted';
  exception when sqlstate '22023' then v_ok:=v_ok||'B';
  end;

  -- Archive hides the record but never deletes it.
  v_res := public.platform_archive_prospect_v184(v_solo,'duplicate test record');
  if v_res->>'status' <> 'archived' then raise exception 'C: %', v_res; end if;
  select count(*) into v_n from app.platform_firm_rows_v88(now()) where prospect_id=v_solo;
  if v_n <> 0 then raise exception 'D: archived record still on the board'; end if;
  select count(*) into v_n from public.sme_prospects where id=v_solo;
  if v_n <> 1 then raise exception 'E: the row was deleted; archive must be soft'; end if;

  if (public.platform_archive_prospect_v184(v_solo,'again'))->>'status' <> 'already_archived' then
    raise exception 'F: archive is not idempotent';
  end if;
  if (public.platform_restore_prospect_v184(v_solo,'false alarm'))->>'status' <> 'restored' then
    raise exception 'G: restore failed';
  end if;
  select count(*) into v_n from app.platform_firm_rows_v88(now()) where prospect_id=v_solo;
  if v_n <> 1 then raise exception 'H: restored record did not come back'; end if;

  -- An archived record refuses edits and stage moves.
  perform public.platform_archive_prospect_v184(v_solo,'park it');
  begin
    perform app.v184_assert_prospect_active(v_solo);
    raise exception 'I: archived record accepted a mutation';
  exception when sqlstate '42501' then v_ok:=v_ok||'I';
  end;
  perform public.platform_restore_prospect_v184(v_solo,'unpark');

  -- Merge moves working data and archives the source with lineage.
  v_res := public.platform_merge_prospects_v184(v_src,v_tgt,'same company entered twice');
  if v_res->>'status' <> 'merged' then raise exception 'J: %', v_res; end if;
  select count(*) into v_n from public.sme_prospect_contacts where prospect_id=v_tgt;
  if v_n <> 2 then raise exception 'K: expected 2 contacts on the survivor, got %', v_n; end if;
  select count(*) into v_n from public.sme_prospect_contacts where prospect_id=v_tgt and is_primary;
  if v_n <> 1 then raise exception 'L: survivor must keep exactly one primary, got %', v_n; end if;
  select count(*) into v_n from app.platform_firm_rows_v88(now()) where prospect_id=v_src;
  if v_n <> 0 then raise exception 'M: merged-away source still on the board'; end if;
  if (select merged_into_prospect_id from public.sme_prospects where id=v_src) <> v_tgt then
    raise exception 'N: merge lineage was not recorded';
  end if;

  -- A merged-away record cannot be revived on its own.
  begin
    perform public.platform_restore_prospect_v184(v_src,'oops');
    raise exception 'O: a merged record was restored';
  exception when sqlstate '42501' then v_ok:=v_ok||'O';
  end;
  begin
    perform public.platform_merge_prospects_v184(v_tgt,v_tgt,'x');
    raise exception 'P: self-merge accepted';
  exception when sqlstate '22023' then v_ok:=v_ok||'P';
  end;

  -- PDPA erasure removes the person, keeps the record and the trail.
  v_res := public.platform_erase_prospect_contact_pii_v184(v_contact,'PDPA erasure request');
  if v_res->>'status' <> 'erased' then raise exception 'Q: %', v_res; end if;
  select count(*) into v_n from public.sme_prospect_contacts
   where id=v_contact and full_name='[erased]' and email is null and phone is null;
  if v_n <> 1 then raise exception 'R: contact personal data was not erased'; end if;

  -- Every destructive verb is audited.
  select count(*) into v_n from public.audit_log
   where action in ('PLATFORM_PROSPECT_ARCHIVED_V184','PLATFORM_PROSPECT_RESTORED_V184',
                    'PLATFORM_PROSPECTS_MERGED_V184','PLATFORM_CONTACT_PII_ERASED_V184')
     and created_at > now() - interval '5 minutes';
  if v_n < 6 then raise exception 'S: expected at least 6 audit rows, got %', v_n; end if;

  raise notice 'v185 archive/merge/erase: all assertions passed (negatives=%)', v_ok;
end
$v185$;

rollback;
