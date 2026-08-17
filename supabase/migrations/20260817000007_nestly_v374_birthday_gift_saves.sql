-- nestly_v374 — the birthday gift editor can save again.
--
-- Every attempt to save a birthday gift has failed since v182 with
--   42701: column "window_mode" specified more than once
-- so the Birthday benefit programme has been unconfigurable for that whole period. v182 added the
-- `window_mode` column and patched this function by asserted string replacement against the live
-- definition; the replacement appended `window_mode` to the INSERT's column list TWICE and never
-- added a matching value or a variable to hold one. PL/pgSQL analyses an INSERT on first
-- execution, so the statement had never run — v182's own verification exercised the reader and the
-- draft->draft clone, both of which were correct, and never the writer.
--
-- The repair is the four lines that were missing, and nothing else: declare v_mode, resolve it
-- from the request (falling back to the stored value, then to the column default 'days'), validate
-- it beside every other field so an unknown mode is refused by the RPC rather than by the table's
-- check constraint, and name `window_mode` once with v_mode supplied for it.
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-17 — see
-- db/tests/v374_birthday_gift_saves.sql. Six checks: the pre-fix definition raises 42701; a whole
-- birthday month saves and stores 'month'; an exact-date window round-trips as days/3/4; an
-- unknown mode is refused with 22023; and the published reader still carries the saved mode.

begin;


-- ---------------------------------------------------------------- public.save_birthday_program_draft
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
  v_discount := case when p_program ? 'discount_percent' then nullif(p_program->>'discount_percent','')::numeric else v_existing.discount_percent end;
  v_item := case when p_program ? 'manual_item' then nullif(btrim(p_program->>'manual_item'),'') else v_existing.manual_item end;
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

-- Grants restated verbatim from production (CREATE OR REPLACE preserves them; these make the
-- privilege surface explicit and re-derivable on a fresh database).
revoke all on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) from public, anon;
grant execute on function public.save_birthday_program_draft(uuid,uuid,jsonb,text) to postgres, service_role, authenticated;

commit;
