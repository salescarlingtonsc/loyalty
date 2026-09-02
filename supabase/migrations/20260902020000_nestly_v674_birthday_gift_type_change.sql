-- nestly_v674 — a PUBLISHED birthday gift can change its type (audit F033).
--
-- Since the birthday module shipped (frenly_v45, 2026-07-21) it has been impossible to switch a
-- live birthday gift from a percentage discount to a free item, or back. Every attempt raises
--   22023: birthday programme values are invalid
-- and nothing is written. The defect class is a merge-with-the-previous-row that ignores the
-- discriminator the same payload is changing:
--
--   1. business_save_birthday_program_v424 opens a draft config version; the AFTER INSERT trigger
--      app.c45_clone_birthday_programs_on_draft copies the LIVE row into that draft — including
--      BOTH benefit columns, one of which is always non-null because
--      birthday_program_versions_fulfillment_check enforces a strict XOR.
--   2. save_birthday_program_draft then fills any key the payload omitted from that clone
--      (`else v_existing.discount_percent` / `else v_existing.manual_item`). The editor sends only
--      the ONE key belonging to the kind it is switching TO, so the OTHER key is inherited from
--      the kind it is switching FROM.
--   3. Its own validation then refuses the result: discount_pct with an item, or free_item with a
--      discount. Both directions fail, 100% of the time, on any firm with a published gift.
--
-- The fix is confined to that inheritance: an omitted benefit field is inherited from the previous
-- row ONLY when it belongs to the fulfillment_kind being saved, and is otherwise null. Nothing
-- else changes — the validation predicate, the whitelist, the idempotency receipt, the snapshot
-- hash contract and the INSERT are untouched, so a payload that explicitly contradicts its own
-- kind (e.g. fulfillment_kind='free_item' WITH discount_percent) is still refused with 22023.
--
-- Client paths fixed by this one change: openBirthdayBenefitEditorV364 (app/app.js) and the legacy
-- deep editor, which both build the same single-key payload.
--
-- VERIFIED inside a rolled-back transaction — see db/tests/v674_birthday_gift_type_change.sql:
-- discount_pct -> free_item and free_item -> discount_pct both publish on an already-published
-- programme, the stored row carries exactly one benefit, and a self-contradicting payload is
-- still refused.

begin;


-- ---------------------------------------------------------------- public.save_birthday_program_draft
-- Body is the live v374 definition; only the two v_discount / v_item resolutions change.
CREATE OR REPLACE FUNCTION public.save_birthday_program_draft(p_config_version uuid, p_program_id uuid, p_program jsonb, p_expected_snapshot_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_header public.firm_config_versions%rowtype;
  v_existing public.birthday_program_versions%rowtype;
  v_hash text;
  v_request_hash text;
  v_replay public.birthday_program_draft_operations%rowtype;
  v_active boolean;
  v_label text;
  v_description text;
  v_terms text;
  v_kind text;
  v_discount numeric(5,2);
  v_item text;
  v_before integer;
  v_after integer;
  v_sort integer;
  v_mode text;
begin
  if p_program_id is null or p_program is null or jsonb_typeof(p_program) <> 'object'
     or p_expected_snapshot_hash is null or length(p_expected_snapshot_hash) <> 32 then
    raise exception 'birthday draft request is invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_program) k where k not in (
    'active','customer_label','customer_description','customer_terms','fulfillment_kind',
    'discount_percent','manual_item','window_days_before','window_days_after','sort','window_mode'
  )) then
    raise exception 'birthday program contains unsupported fields' using errcode = '22023';
  end if;
  v_request_hash := app.c45_hash(jsonb_build_object('program_id',p_program_id,'program',p_program)::text);
  select * into v_header from public.firm_config_versions where id = p_config_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then raise exception 'only a draft birthday program may be edited' using errcode = '42501'; end if;
  select * into v_replay from public.birthday_program_draft_operations
   where config_version_id=p_config_version and actor=auth.uid() and program_id=p_program_id
     and expected_snapshot_hash=p_expected_snapshot_hash for share;
  if found then
    if v_replay.request_hash is distinct from v_request_hash then
      raise exception 'birthday draft request conflicts with an existing operation' using errcode = '40001';
    end if;
    return jsonb_build_object('status','draft','snapshot_hash',v_replay.result_snapshot_hash,'replayed',true);
  end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving' using errcode = '40001';
  end if;
  select * into v_existing from public.birthday_program_versions
   where config_version_id=p_config_version and business_id=v_header.business_id and program_id=p_program_id for update;
  if v_existing.id is null and exists (
    select 1 from public.birthday_program_versions p
     where p.config_version_id=p_config_version and p.business_id=v_header.business_id
  ) then
    raise exception 'only one birthday program may exist in a configuration version' using errcode='22023';
  end if;
  if v_existing.id is null then
    if exists (select 1 from public.birthday_programs where id=p_program_id and business_id<>v_header.business_id) then
      raise exception 'birthday program does not belong to this business' using errcode = '42501';
    end if;
    insert into public.birthday_programs(id,business_id) values(p_program_id,v_header.business_id)
      on conflict (id) do nothing;
  end if;
  v_active := case when p_program ? 'active' then (p_program->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_label := coalesce(nullif(btrim(p_program->>'customer_label'),''),v_existing.customer_label);
  v_description := coalesce(nullif(btrim(p_program->>'customer_description'),''),v_existing.customer_description);
  v_terms := coalesce(nullif(btrim(p_program->>'customer_terms'),''),v_existing.customer_terms);
  v_kind := coalesce(nullif(btrim(p_program->>'fulfillment_kind'),''),v_existing.fulfillment_kind);
  -- v674: an omitted benefit field is inherited from the previous row only when it belongs to the
  -- kind being saved. Without this, switching kind inherits the OTHER kind's value from the clone
  -- the draft trigger made, and the validation below refuses the owner's own edit.
  v_discount := case when p_program ? 'discount_percent' then nullif(p_program->>'discount_percent','')::numeric
                     when v_kind = 'discount_pct' then v_existing.discount_percent
                     else null end;
  v_item := case when p_program ? 'manual_item' then nullif(btrim(p_program->>'manual_item'),'')
                 when v_kind = 'free_item' then v_existing.manual_item
                 else null end;
  v_before := case when p_program ? 'window_days_before' then (p_program->>'window_days_before')::integer else coalesce(v_existing.window_days_before,0) end;
  v_after := case when p_program ? 'window_days_after' then (p_program->>'window_days_after')::integer else coalesce(v_existing.window_days_after,0) end;
  v_sort := case when p_program ? 'sort' then (p_program->>'sort')::integer else coalesce(v_existing.sort,0) end;
  v_mode := case when p_program ? 'window_mode' then nullif(btrim(p_program->>'window_mode'),'')
                 else coalesce(v_existing.window_mode,'days') end;
  if v_label is null or v_description is null or v_terms is null or v_kind not in ('discount_pct','free_item')
     or v_before not between 0 and 182 or v_after not between 0 and 182 or v_before+v_after+1 > 365
     or v_sort not between 0 and 10000 or v_mode not in ('days','month')
     or (v_kind='discount_pct' and (v_discount is null or v_discount<=0 or v_discount>100 or v_item is not null))
     or (v_kind='free_item' and (v_discount is not null or v_item is null)) then
    raise exception 'birthday programme values are invalid' using errcode = '22023';
  end if;
  insert into public.birthday_program_versions(
    program_id,config_version_id,business_id,active,customer_label,customer_description,
    customer_terms,fulfillment_kind,discount_percent,manual_item,window_days_before,window_days_after,sort,window_mode
  ) values(
    p_program_id,p_config_version,v_header.business_id,v_active,v_label,v_description,
    v_terms,v_kind,v_discount,v_item,v_before,v_after,v_sort,v_mode
  ) on conflict(program_id,config_version_id) do update set
    active=excluded.active, customer_label=excluded.customer_label,
    customer_description=excluded.customer_description, customer_terms=excluded.customer_terms,
    fulfillment_kind=excluded.fulfillment_kind, discount_percent=excluded.discount_percent,
    manual_item=excluded.manual_item, window_mode=excluded.window_mode, window_days_before=excluded.window_days_before,
    window_days_after=excluded.window_days_after, sort=excluded.sort;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  insert into public.birthday_program_draft_operations(
    config_version_id,business_id,actor,program_id,expected_snapshot_hash,request_hash,result_snapshot_hash
  ) values(p_config_version,v_header.business_id,auth.uid(),p_program_id,p_expected_snapshot_hash,v_request_hash,v_hash);
  return jsonb_build_object('status','draft','snapshot_hash',v_hash,'replayed',false);
end $function$;

comment on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) is
  'v674: writes one birthday programme into a draft config version. An omitted discount_percent / '
  'manual_item is inherited from the previous version only when it belongs to the fulfillment_kind '
  'being saved, so switching a published gift between discount_pct and free_item succeeds; a '
  'payload that names the field of the other kind is still refused with 22023.';

-- Grants restated verbatim from production (CREATE OR REPLACE preserves them; these make the
-- privilege surface explicit and re-derivable on a fresh database).
revoke all on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) from public, anon;
grant execute on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) to postgres, service_role, authenticated;

commit;
