-- NESTLY v184 — the CRM's missing exit doors: archive, merge and PDPA erasure.
--
-- Until now the CRM had no delete, archive or merge path of any kind: 129
-- platform RPCs and not one of them could remove or combine a record. The
-- costs were concrete — production already carries a duplicate
-- ("CARLINGTON SMITH CONSULTANCY PTE. LTD." twice) that no operator could
-- resolve, and a prospect contact's personal data had no erasure route, which
-- a PDPA access/erasure request needs. ⚖️ Confirm the retention wording with
-- counsel; this migration supplies the mechanism, not the policy.
--
-- Design, and why:
--   * ARCHIVE IS SOFT. Rows are never deleted. archived_at hides a prospect
--     from every operator surface while the audit trail, stage history and
--     evidence stay exactly where they happened. Restorable.
--   * ONLY PRE-FIRM PROSPECTS CAN BE ARCHIVED. If a business points at the
--     prospect (converted_business_id or businesses.source_prospect_id), the
--     archive is refused. That is not a nicety: the firm directory anchors a
--     converted firm through its prospect, so archiving one would make a live
--     paying firm vanish from the board entirely. The guard keeps the
--     directory's two anchor paths total.
--   * MERGE MOVES WORKING DATA, NEVER HISTORY. Contacts, activities, tasks,
--     tags, documents and source lineage follow the survivor. Stage history,
--     stage-entry evidence, quality snapshots, qualification/commercial
--     versions and import ledger rows stay attached to the source record,
--     because they are the audit of what happened to *that* record and
--     rewriting them would forge the trail.
--   * ERASURE IS SURGICAL. The PDPA path scrubs one contact's personal data
--     (name, email, phone and its profile versions) and leaves the row, the
--     prospect and the audit trail intact.
--   * SUPER ADMIN ONLY. These are the destructive verbs; the ordinary
--     platform-operator role keeps its existing create/update surface.
--
-- Every write is audited. Archive/restore/merge/erase are idempotent by
-- outcome: repeating them is a no-op, not an error.

begin;

alter table public.sme_prospects
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id),
  add column if not exists archive_reason text,
  add column if not exists merged_into_prospect_id uuid references public.sme_prospects(id);

-- Board and list reads filter on this constantly; keep active lookups cheap.
create index if not exists sme_prospects_active_idx
  on public.sme_prospects(updated_at desc) where archived_at is null;

-- An erased contact has, by definition, no email and no phone. The original
-- check demanded one or the other unconditionally, which made PDPA erasure
-- impossible to represent. Require a channel only while the contact is active;
-- every existing row satisfies the stricter form, so this only widens.
alter table public.sme_prospect_contacts
  drop constraint if exists sme_prospect_contacts_channel_check;
alter table public.sme_prospect_contacts
  add constraint sme_prospect_contacts_channel_check
  check (active = false or email is not null or phone is not null);

comment on column public.sme_prospects.archived_at is
  'v184 soft delete. Non-null hides the prospect from operator surfaces; the row, its history and its audit trail are retained.';
comment on column public.sme_prospects.merged_into_prospect_id is
  'v184 merge lineage. Set on the source record when it was merged into a surviving prospect.';

-- Refuses when a prospect has been archived. Mutation entry points call this
-- so an archived record cannot be edited or moved through the API.
create or replace function app.v184_assert_prospect_active(p_prospect uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_archived timestamptz;
begin
  select archived_at into v_archived from public.sme_prospects where id=p_prospect;
  if v_archived is not null then
    raise exception 'this firm record is archived; restore it before making changes'
      using errcode='42501';
  end if;
end $$;

-- A prospect that a business points at is load-bearing for the firm
-- directory. Archiving it would remove a live firm from every board.
create or replace function app.v184_assert_archivable(p_prospect uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.sme_prospects%rowtype; v_business uuid;
begin
  select * into v_row from public.sme_prospects where id=p_prospect;
  if not found then
    raise exception 'firm record not found' using errcode='22023';
  end if;
  if v_row.converted_business_id is not null then
    raise exception 'this firm already has a workspace and cannot be archived'
      using errcode='42501';
  end if;
  select id into v_business from public.businesses
   where source_prospect_id=p_prospect limit 1;
  if v_business is not null then
    raise exception 'a workspace was created from this record and cannot be archived'
      using errcode='42501';
  end if;
end $$;

create or replace function public.platform_archive_prospect_v184(
  p_prospect uuid, p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_row public.sme_prospects%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'')='' then
    raise exception 'a reason is required to archive a firm record' using errcode='22023';
  end if;
  select * into v_row from public.sme_prospects where id=p_prospect;
  if not found then
    raise exception 'firm record not found' using errcode='22023';
  end if;
  if v_row.archived_at is not null then
    return jsonb_build_object('status','already_archived','prospect',p_prospect,
      'archived_at',v_row.archived_at);
  end if;
  perform app.v184_assert_archivable(p_prospect);

  update public.sme_prospects
     set archived_at=now(), archived_by=v_actor, archive_reason=btrim(p_reason),
         updated_at=now(), updated_by=v_actor
   where id=p_prospect;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_PROSPECT_ARCHIVED_V184','sme_prospects',p_prospect,
    jsonb_build_object('reason',btrim(p_reason),'stage',v_row.current_stage_key));
  return jsonb_build_object('status','archived','prospect',p_prospect);
end $$;

create or replace function public.platform_restore_prospect_v184(
  p_prospect uuid, p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_row public.sme_prospects%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  select * into v_row from public.sme_prospects where id=p_prospect;
  if not found then
    raise exception 'firm record not found' using errcode='22023';
  end if;
  if v_row.archived_at is null then
    return jsonb_build_object('status','already_active','prospect',p_prospect);
  end if;
  -- A merged-away record must not be revived on its own: it would resurrect
  -- a duplicate whose data now lives on the survivor.
  if v_row.merged_into_prospect_id is not null then
    raise exception 'this record was merged into another firm and cannot be restored'
      using errcode='42501';
  end if;

  update public.sme_prospects
     set archived_at=null, archived_by=null, archive_reason=null,
         updated_at=now(), updated_by=v_actor
   where id=p_prospect;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_PROSPECT_RESTORED_V184','sme_prospects',p_prospect,
    jsonb_build_object('reason',nullif(btrim(coalesce(p_reason,'')),''),
      'was_archived_at',v_row.archived_at));
  return jsonb_build_object('status','restored','prospect',p_prospect);
end $$;

create or replace function public.platform_merge_prospects_v184(
  p_source uuid, p_target uuid, p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();
  v_source public.sme_prospects%rowtype;
  v_target public.sme_prospects%rowtype;
  v_moved jsonb:='{}'::jsonb;
  v_count integer;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if p_source is null or p_target is null or p_source=p_target then
    raise exception 'choose two different firm records to merge' using errcode='22023';
  end if;
  if coalesce(btrim(p_reason),'')='' then
    raise exception 'a reason is required to merge firm records' using errcode='22023';
  end if;
  select * into v_source from public.sme_prospects where id=p_source;
  if not found then raise exception 'source firm record not found' using errcode='22023'; end if;
  select * into v_target from public.sme_prospects where id=p_target;
  if not found then raise exception 'surviving firm record not found' using errcode='22023'; end if;
  if v_source.archived_at is not null then
    raise exception 'the record being merged away is already archived' using errcode='22023';
  end if;
  if v_target.archived_at is not null then
    raise exception 'the surviving record is archived; restore it first' using errcode='22023';
  end if;
  -- The source disappears from the board, so it must satisfy the same rule as
  -- a plain archive: nothing may have become a workspace from it.
  perform app.v184_assert_archivable(p_source);

  -- Working data follows the survivor.
  -- An incoming contact never displaces the survivor's primary contact.
  update public.sme_prospect_contacts
     set prospect_id=p_target,
         is_primary=case when exists(
           select 1 from public.sme_prospect_contacts existing
            where existing.prospect_id=p_target and existing.is_primary
         ) then false else is_primary end
   where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('contacts',v_count);

  update public.sme_prospect_activities set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('activities',v_count);

  update public.sme_prospect_tasks set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('tasks',v_count);

  update public.sme_document_versions set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('documents',v_count);

  update public.sme_prospect_source_lineage set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('source_lineage',v_count);

  -- Tags are keyed (prospect_id, tag_id): drop the ones the survivor already
  -- carries, then move the rest.
  delete from public.sme_prospect_tags source_tag
   where source_tag.prospect_id=p_source
     and exists(select 1 from public.sme_prospect_tags kept
                 where kept.prospect_id=p_target and kept.tag_id=source_tag.tag_id);
  update public.sme_prospect_tags set prospect_id=p_target where prospect_id=p_source;
  get diagnostics v_count=row_count; v_moved:=v_moved||jsonb_build_object('tags',v_count);

  -- History, evidence and quality stay with the record they describe.
  update public.sme_prospects
     set archived_at=now(), archived_by=v_actor,
         archive_reason=btrim(p_reason), merged_into_prospect_id=p_target,
         updated_at=now(), updated_by=v_actor
   where id=p_source;
  update public.sme_prospects
     set updated_at=now(), updated_by=v_actor
   where id=p_target;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_PROSPECTS_MERGED_V184','sme_prospects',p_target,
    jsonb_build_object('source',p_source,'target',p_target,
      'reason',btrim(p_reason),'moved',v_moved));
  return jsonb_build_object('status','merged','source',p_source,'target',p_target,
    'moved',v_moved);
end $$;

-- PDPA erasure for one person's data on a prospect contact. The contact row
-- and every downstream reference survive; only the personal data is removed,
-- and the erasure itself is audited.
create or replace function public.platform_erase_prospect_contact_pii_v184(
  p_contact uuid, p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_prospect uuid; v_versions integer:=0;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'')='' then
    raise exception 'a reason is required to erase personal data' using errcode='22023';
  end if;
  select prospect_id into v_prospect from public.sme_prospect_contacts where id=p_contact;
  if v_prospect is null then
    raise exception 'contact not found' using errcode='22023';
  end if;

  update public.sme_prospect_contacts
     set full_name='[erased]', email=null, phone=null, active=false, updated_at=now()
   where id=p_contact;

  -- The profile history is columnar, so each personal field is nulled in
  -- place. do_not_contact is deliberately forced true rather than erased: an
  -- erasure request is also a standing instruction never to contact again.
  update public.sme_contact_profile_versions
     set preferred_name=null, mobile_original=null, mobile_e164=null,
         office_phone_original=null, office_phone_e164=null,
         whatsapp_original=null, whatsapp_e164=null,
         profile_url=null, contact_hours=null, notes=null,
         marketing_opt_in=false, do_not_contact=true
   where contact_id=p_contact;
  get diagnostics v_versions=row_count;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_CONTACT_PII_ERASED_V184','sme_prospect_contacts',p_contact,
    jsonb_build_object('prospect',v_prospect,'reason',btrim(p_reason),
      'profile_versions_scrubbed',v_versions));
  return jsonb_build_object('status','erased','contact',p_contact,
    'profile_versions_scrubbed',v_versions);
end $$;

revoke all on function public.platform_archive_prospect_v184(uuid,text) from public, anon, authenticated;
revoke all on function public.platform_restore_prospect_v184(uuid,text) from public, anon, authenticated;
revoke all on function public.platform_merge_prospects_v184(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.platform_erase_prospect_contact_pii_v184(uuid,text) from public, anon, authenticated;
grant execute on function public.platform_archive_prospect_v184(uuid,text) to authenticated;
grant execute on function public.platform_restore_prospect_v184(uuid,text) to authenticated;
grant execute on function public.platform_merge_prospects_v184(uuid,uuid,text) to authenticated;
grant execute on function public.platform_erase_prospect_contact_pii_v184(uuid,text) to authenticated;
revoke all on function app.v184_assert_prospect_active(uuid) from public, anon, authenticated;
revoke all on function app.v184_assert_archivable(uuid) from public, anon, authenticated;

-- Read paths: hide archived records from the board/directory and the CRM list.
do $v184_reads$
declare
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
begin
  -- 1) app.platform_firm_rows_v88 — the anchor query behind the directory,
  --    the Kanban, the list view and every attention count.
  v_def := pg_get_functiondef(to_regprocedure('app.platform_firm_rows_v88(timestamptz)'));
  v_old := 'where prospect.created_at <= p_snapshot_at';
  v_new := 'where prospect.archived_at is null and prospect.created_at <= p_snapshot_at';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v184: expected one prospect anchor filter in firm_rows_v88, found %', v_hits;
  end if;
  if position('archived_at' in v_def) > 0 then
    raise exception 'v184: firm_rows_v88 already filters archived rows';
  end if;
  execute replace(v_def, v_old, v_new);

  -- 2) public.platform_list_prospects_v76 — the CRM list contract. Both the
  --    page query and its cursor query end in the same search predicate.
  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_list_prospects_v76(text,uuid,text,integer,timestamptz)'));
  v_old := 'app.sme_prospect_search_match_v76(prospect.id,p_search)';
  v_new := 'app.sme_prospect_search_match_v76(prospect.id,p_search) and prospect.archived_at is null';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits < 2 then
    raise exception 'v184: expected the search predicate at least twice, found %', v_hits;
  end if;
  if position('archived_at' in v_def) > 0 then
    raise exception 'v184: list_prospects_v76 already filters archived rows';
  end if;
  execute replace(v_def, v_old, v_new);
end
$v184_reads$;

-- Mutation guards: an archived record cannot be edited or moved.
do $v184_writes$
declare
  v_def text;
  v_old text;
  v_hits integer;
begin
  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_move_prospect_stage_v86(uuid,text,bigint,jsonb,jsonb,text)'));
  v_old := '  perform app.validate_stage_entry_v86(p_prospect,p_to_stage,p_entry_evidence,p_commercial_terms);';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v184: expected one validate_stage_entry call, found %', v_hits;
  end if;
  if position('v184_assert_prospect_active' in v_def) > 0 then
    raise exception 'v184: stage move already guarded';
  end if;
  execute replace(v_def, v_old,
    '  perform app.v184_assert_prospect_active(p_prospect);' || chr(10) || v_old);

  v_def := pg_get_functiondef(to_regprocedure(
    'public.platform_update_prospect_v76(uuid,bigint,jsonb,text)'));
  v_old := '  if jsonb_typeof(p_patch)<>''object'' then raise exception ''patch must be an object'' using errcode=''22023''; end if;';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v184: expected one patch-type check in update_prospect, found %', v_hits;
  end if;
  if position('v184_assert_prospect_active' in v_def) > 0 then
    raise exception 'v184: prospect update already guarded';
  end if;
  execute replace(v_def, v_old,
    v_old || chr(10) || '  perform app.v184_assert_prospect_active(p_prospect);');
end
$v184_writes$;

commit;
