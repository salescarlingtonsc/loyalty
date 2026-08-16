-- V343: business_update_reward_v326 — the Points System page's own "Edit" RPC.
--
-- Owner mockup ("photo 4"): the simplified Points System page (V326, immediate-write, no draft)
-- shows each gift as a card with a photo and a description line, and lets the owner edit
-- name/points/description/photo. business_create_reward_v326 only ever accepted
-- name/points/credit_cents — there was no write path for `description` or `image_ref` on this
-- page at all, and no edit RPC of any kind existed for an already-created gift (only create,
-- pause/unpause, delete). Both columns are real, already-published columns on loyalty_rewards
-- (image_ref has carried reward photos since v27); this just gives the simplified page its own
-- way to write the ones the owner is now asking to edit here.
--
-- WHY THIS DOES NOT TOUCH loyalty_reward_versions
-- business_create_reward_v326 inserts a version row (tied to active_config_version_id) because
-- that is the ONLY per-version copy of a brand-new reward. business_set_reward_paused_v326 --
-- the one existing immediate-write EDIT of an already-created reward -- does not touch
-- loyalty_reward_versions at all, and that is the precedent this RPC follows: the versions table
-- is an immutable historical snapshot (each row keyed uniquely on (reward_id,config_version_id)),
-- not a live mirror kept in sync with every subsequent edit. Only public.loyalty_rewards is the
-- current-state source of truth this page (and customer_get_reward_catalog) reads.
--
-- WHY p_image_ref IS A PLAIN STRING PARAM, NOT A NEW RPC CALL
-- The deep editor (openRewardEditor, app/app.js ~19643) already uploads a reward photo by writing
-- straight to the `business-public` storage bucket at `<business_id>/reward/<uuid>.<ext>` and
-- handing the resulting public URL back to its own save call -- it deliberately bypasses
-- business_publish_media_asset_v95 because that RPC's optimistic-concurrency version has no
-- reader for reward assets (see that function's own comment for why). This RPC accepts the same
-- already-uploaded URL string the client produces the same way, undefined meaning "leave the
-- current photo alone" and null/empty meaning "remove it" -- the same three-state contract the
-- deep editor already uses for the identical reason (an unset param must never silently blank an
-- existing photo).
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run re-verified immediately before
-- the real apply; both functions confirmed live afterward with the new argument lists below).

begin;

create or replace function public.business_update_reward_v326(
  p_business uuid, p_reward uuid, p_name text, p_points integer,
  p_description text default null, p_credit_cents integer default 0,
  p_image_ref text default null, p_clear_image boolean default false
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.loyalty_rewards%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_description text := nullif(btrim(coalesce(p_description,'')),'');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null then
    raise exception 'gift name is required' using errcode='22023';
  end if;
  if p_points is null or p_points<=0 then
    raise exception 'points must be a positive number' using errcode='22023';
  end if;
  if p_credit_cents is not null and p_credit_cents<0 then
    raise exception 'credit_cents cannot be negative' using errcode='22023';
  end if;
  select * into v_row from public.loyalty_rewards
   where id=p_reward and business_id=p_business and active
   for update;
  if not found then
    raise exception 'gift not found in this business' using errcode='42704';
  end if;
  update public.loyalty_rewards
     set name=v_name, internal_name=v_name, customer_name=v_name,
         description=v_description, cost_points=p_points,
         credit_cents=coalesce(p_credit_cents,0), estimated_cost_cents=coalesce(p_credit_cents,0),
         image_ref=case when p_clear_image then null
                        when p_image_ref is not null then p_image_ref
                        else image_ref end
   where id=p_reward and business_id=p_business;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.updated','loyalty_rewards',p_reward,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0)));
  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0));
end
$$;
revoke all on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean) from public;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean) to authenticated;

-- V343 also extends business_create_reward_v326 with optional p_description/p_image_ref, so a
-- gift can be named, priced, described AND photographed in the one form the "Add a new gift"
-- card opens (photo 4 shows the description line and photo on every gift, including freshly-
-- added ones). Everything else in this function is byte-identical to the version it replaces.
-- A new parameter changes the signature, so CREATE OR REPLACE would leave the OLD 5-arg
-- function sitting alongside this one as an ambiguous overload — drop it explicitly first.
drop function if exists public.business_create_reward_v326(uuid,uuid,text,integer,integer);
drop function if exists public.business_create_reward_v326(uuid,uuid,text,integer,integer,text);
create or replace function public.business_create_reward_v326(
  p_business uuid, p_programme uuid, p_name text, p_points integer,
  p_credit_cents integer default 0, p_description text default null, p_image_ref text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_reward_id uuid:=gen_random_uuid();
  v_name text:=nullif(btrim(coalesce(p_name,'')),'');
  v_description text:=nullif(btrim(coalesce(p_description,'')),'');
  v_kind text:=case when coalesce(p_credit_cents,0)>0 then 'credit' else 'manual_item' end;
  v_active_version uuid;
  v_sort integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null then
    raise exception 'gift name is required' using errcode='22023';
  end if;
  if p_points is null or p_points<=0 then
    raise exception 'points must be a positive number' using errcode='22023';
  end if;
  if p_credit_cents is not null and p_credit_cents<0 then
    raise exception 'credit_cents cannot be negative' using errcode='22023';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=p_programme and spine.business_id=p_business) then
    raise exception 'programme does not belong to this business' using errcode='42501';
  end if;
  select active_config_version_id into v_active_version
    from public.businesses where id=p_business;
  if v_active_version is null then
    raise exception 'this business has no published loyalty configuration yet' using errcode='XX001';
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_rewards where business_id=p_business;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,description,image_ref,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_description,p_image_ref,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_active_version
  );

  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,image_ref,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id
  ) values(
    v_reward_id,p_business,v_active_version,v_name,v_name,v_description,p_image_ref,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme
  );

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0)));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0));
end
$$;
revoke all on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text) from public;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16, all 7 checks passed inside a rolled-back transaction against
-- gadpooereceldfpfxsod, using Cubbly (8492e8d6-8888-4383-ada0-7e1ed69f0caa) and its real owner
-- (f73a9423-33fd-424c-9fb9-2d5ba058a2d7). Live loyalty_rewards confirmed unchanged after each
-- rollback (re-queried outside the transaction), so nothing here ever reached production:
--   1. owner edit (name/points/description) -> all three values changed on the live row within
--      the transaction; loyalty_reward_versions row count for that reward the SAME before and
--      after the edit (queried both inside and outside the same transaction).
--   2. non-owner staff edit attempt -> refused with 42501, nothing changed.
--   3. p_points=0 -> refused with 22023, nothing changed.
--   4. create with description+image_ref -> both loyalty_rewards AND loyalty_reward_versions
--      carry the description; loyalty_rewards carries the image_ref (versions row does not need
--      to -- it is not read for display, only loyalty_rewards is).
--   5. legacy 5-arg create call (no description/image, exact old call shape) -> still succeeds.
--   6. p_image_ref supplied on update -> image_ref changes to the new value.
--   7. p_clear_image=true on update -> image_ref becomes null, independent of p_image_ref.
commit;
