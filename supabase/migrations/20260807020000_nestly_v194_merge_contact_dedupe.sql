-- NESTLY v194 — merging two records for the same firm must not duplicate the
-- same person.
--
-- Found while merging the real production duplicate: both
-- "CARLINGTON SMITH CONSULTANCY PTE. LTD." records carried the identical
-- contact (same name, same email). v185's merge moved contacts unconditionally,
-- so the survivor would have ended up listing Lee Chuan Seng twice — a clean
-- merge producing dirty data.
--
-- A source contact is now treated as the same person when the survivor already
-- has a contact with the same email (case- and space-insensitive), or the same
-- phone when neither row carries an email. Duplicates are LEFT ON THE ARCHIVED
-- SOURCE rather than moved or deleted: nothing is lost, the row stays available
-- for audit, and it simply stops being surfaced because its record is archived.
-- The merge result reports moved and duplicate counts separately so the
-- operator can see what happened.

begin;

do $v194$
declare
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
begin
  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_merge_prospects_v184(uuid,uuid,text)'));
  if v_def is null then
    raise exception 'v194: platform_merge_prospects_v184 is missing';
  end if;
  if position('duplicate_contacts' in v_def) > 0 then
    raise exception 'v194: merge already dedupes contacts';
  end if;

  v_old := '  update public.sme_prospect_contacts
     set prospect_id=p_target,
         is_primary=case when exists(select 1 from public.sme_prospect_contacts e
           where e.prospect_id=p_target and e.is_primary) then false else is_primary end
   where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object(''contacts'',v_count);';

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v194: expected one contact-move block, found %', v_hits;
  end if;

  v_new := '  update public.sme_prospect_contacts source_contact
     set prospect_id=p_target,
         is_primary=case when exists(select 1 from public.sme_prospect_contacts e
           where e.prospect_id=p_target and e.is_primary) then false else is_primary end
   where source_contact.prospect_id=p_source
     and not exists (
       select 1 from public.sme_prospect_contacts kept
        where kept.prospect_id=p_target
          and (
            (source_contact.email is not null and kept.email is not null
              and lower(btrim(kept.email))=lower(btrim(source_contact.email)))
            or (source_contact.email is null and kept.email is null
              and source_contact.phone is not null and kept.phone is not null
              and btrim(kept.phone)=btrim(source_contact.phone))
          )
     );
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object(''contacts'',v_count);
  select count(*) into v_count from public.sme_prospect_contacts
   where prospect_id=p_source;
  v_moved:=v_moved||jsonb_build_object(''duplicate_contacts'',v_count);';

  execute replace(v_def, v_old, v_new);
end
$v194$;

commit;
