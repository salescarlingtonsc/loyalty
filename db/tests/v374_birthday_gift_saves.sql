-- Rollback-only acceptance for v374 — the birthday gift editor can save again.
--   supabase db query --linked -f db/tests/v374_birthday_gift_saves.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Check 01 fails on the pre-v374 function: v182 patched save_birthday_program_draft by asserted
-- string replacement and appended `window_mode` to the INSERT column list TWICE while supplying
-- no value for it, so every save of a birthday gift has raised 42701 since v182 was applied.
-- Checks 02-05 prove the repaired function stores the mode the owner picked, in both directions,
-- and still refuses a mode outside the column's own check constraint.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner uuid, slug text, draft uuid, prog uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug,prog) values ('zz-v374-'||substr(md5(random()::text),1,8), gen_random_uuid());

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V374',slug,array['loyalty'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v374-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V374 Owner' from _c;
-- the owner write gate needs an approved, unpaused workspace (a trigger seeds both rows)
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v374 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

create or replace function pg_temp.stored_v374() returns text language sql security definer as $$
  select coalesce((select window_mode||'/'||window_days_before||'/'||window_days_after
    from public.birthday_program_versions
   where config_version_id=(select draft from _c) and program_id=(select prog from _c)),'none')
$$;
grant execute on function pg_temp.stored_v374() to authenticated;

-- A minimum published loyalty configuration for the draft to be based on.
insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
select cfg,biz,1,'draft','manual',md5('v374-base'),owner from (select *, gen_random_uuid() as cfg from _c) x;
update _c set draft=(select id from public.firm_config_versions where business_id=(select biz from _c));
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
insert into public.loyalty_program_versions(config_version_id,business_id,kind,loyalty_model,active,
  earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
select draft,biz,'points','points_tiers',true,1,150,0,'points_earned','none' from _c;
select set_config('request.jwt.claims','{}',true);
update public.firm_config_versions set status='published',published_at=now()
 where id=(select draft from _c);
insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
select biz,'points',true,'points_tiers','published',draft from _c;
select set_config('app.v79_system_transition','on',true);
update public.businesses set active_config_version_id=(select draft from _c) where id=(select biz from _c);
select set_config('app.v79_system_transition','off',true);

-- Everything below runs as the owner, through the same RPCs the browser calls.
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

update _c set draft=(public.create_loyalty_config_draft(biz,null,'v374-acceptance')::jsonb->>'version_id')::uuid;

create or replace function pg_temp.save_birthday_v374(p_mode text, p_before integer, p_after integer)
returns text language plpgsql as $$
declare v_hash text; v_c record;
begin
  select * into v_c from _c limit 1;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_c.draft;
  perform public.save_birthday_program_draft(v_c.draft, v_c.prog, jsonb_build_object(
    'active',true,'customer_label','Birthday treat','customer_description','Test',
    'customer_terms','Na','fulfillment_kind','free_item','manual_item','Facial',
    'window_mode',p_mode,'window_days_before',p_before,'window_days_after',p_after,'sort',0
  ), v_hash);
  return 'ok';
exception when others then return sqlstate||' '||sqlerrm;
end $$;

-- 01 — the defect itself, on whatever definition is live right now.
insert into _r select '01 pre-fix save fails with a duplicated column',
  case when pg_temp.save_birthday_v374('month',0,0) like '42701%'
    then 'PASS (42701 duplicate column, as reported by the owner)'
    else 'INFO already repaired: '||pg_temp.save_birthday_v374('month',0,0) end;

reset role;
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
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 02 — a whole-birthday-month gift saves, and stores the mode the owner picked.
insert into _r select '02 month mode saves', case when pg_temp.save_birthday_v374('month',0,0)='ok'
  then 'PASS' else 'FAIL '||pg_temp.save_birthday_v374('month',0,0) end;
insert into _r select '03 month mode is what was stored',
  case when pg_temp.stored_v374() like 'month/%' then 'PASS'
  else 'FAIL stored mode is '||pg_temp.stored_v374() end;

-- 04 — switching to an exact-date window persists both the mode and its days.
insert into _r select '04 days mode saves and keeps its window',
  case when pg_temp.save_birthday_v374('days',3,4)='ok' and pg_temp.stored_v374()='days/3/4'
  then 'PASS' else 'FAIL days mode did not round-trip, stored '||pg_temp.stored_v374() end;

-- 05 — a mode outside the column's check constraint is refused by the RPC, not by the table.
insert into _r select '05 an unknown mode is refused',
  case when pg_temp.save_birthday_v374('fortnight',0,0) like '22023%'
  then 'PASS' else 'FAIL unknown mode was not refused: '||pg_temp.save_birthday_v374('fortnight',0,0) end;

-- 06 — the published reader still answers with the saved mode.
select public.publish_loyalty_config((select draft from _c));
insert into _r select '06 published reader carries the mode',
  case when public.get_active_birthday_program((select biz from _c))#>>'{programs,0,window_mode}'='days'
  then 'PASS' else 'FAIL published birthday lost its window mode' end;

reset role;
select k as check, v as result from _r order by k;

rollback;
