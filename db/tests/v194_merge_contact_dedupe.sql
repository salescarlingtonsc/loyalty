-- Rollback-only v194 acceptance: merging two records for the same firm must
-- not list the same person twice on the survivor.
begin;

do $v194$
declare
  v_sa uuid; v_co uuid; v_src uuid; v_tgt uuid; v_res jsonb; v_n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  insert into public.sme_companies(legal_name) values ('V194 Fixture') returning id into v_co;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_src;
  insert into public.sme_prospects(company_id,current_stage_key,created_by)
    values (v_co,'new_lead',v_sa) returning id into v_tgt;
  -- The same person on both records (differing only by case and spacing),
  -- plus one genuinely new person that must still move.
  insert into public.sme_prospect_contacts(prospect_id,full_name,email,is_primary)
    values (v_src,'Lee Chuan Seng','LeeChuanSeng.biz@gmail.com ',true),
           (v_src,'Second Person','second@example.com',false),
           (v_tgt,'Lee Chuan Seng','leechuanseng.biz@gmail.com',true);

  v_res := public.platform_merge_prospects_v184(v_src,v_tgt,'same firm entered twice');
  if (v_res#>>'{moved,contacts}')::int <> 1 then
    raise exception 'A: expected exactly the new person to move, got %', v_res->'moved';
  end if;
  if (v_res#>>'{moved,duplicate_contacts}')::int <> 1 then
    raise exception 'B: expected 1 duplicate reported, got %', v_res->'moved';
  end if;
  select count(*) into v_n from public.sme_prospect_contacts where prospect_id=v_tgt;
  if v_n <> 2 then raise exception 'C: survivor should hold 2 distinct people, got %', v_n; end if;
  select count(*) into v_n from public.sme_prospect_contacts
   where prospect_id=v_tgt and lower(btrim(email))='leechuanseng.biz@gmail.com';
  if v_n <> 1 then raise exception 'D: the same person appears % times', v_n; end if;
  -- Nothing is destroyed: the duplicate stays on the archived source.
  select count(*) into v_n from public.sme_prospect_contacts where prospect_id=v_src;
  if v_n <> 1 then raise exception 'E: duplicate must be retained on the source, got %', v_n; end if;
  select count(*) into v_n from public.sme_prospect_contacts where prospect_id=v_tgt and is_primary;
  if v_n <> 1 then raise exception 'F: survivor must keep exactly one primary, got %', v_n; end if;

  raise notice 'v194 merge contact dedupe: all assertions passed';
end
$v194$;

rollback;
