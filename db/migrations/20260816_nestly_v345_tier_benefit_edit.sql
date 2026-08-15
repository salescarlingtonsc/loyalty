-- V345: tier "benefit" text on the simplified Manage Tiers page (growTiersManageV331, app/app.js
-- ~23185), owner screenshots 2026-08-16 ("free item / 10% discount / free xx every month").
--
-- perk_note is NOT a new column -- public.loyalty_tiers has carried it since v23
-- (20260720_frenly_v23_loyalty_points_tiers.sql), and it already renders on the customer tier
-- ladder (20260813_nestly_v310_programme_read_path.sql). It was only ever writable from the
-- wizard's advanced draft-based tier form (saveTierFormV304) -- business_create_tier_v331 (v331)
-- never accepted it, and there has never been an immediate-write UPDATE rpc for an existing tier's
-- name/threshold/perk at all (v331 only ever shipped create/pause/delete). This migration:
--   1. extends business_create_tier_v331 with p_perk_note (additive default, old callers unaffected)
--   2. adds business_update_tier_v331, mirroring business_update_reward_v326's exact shape and
--      precedent: it only ever writes public.loyalty_tiers (the live source of truth) and never
--      touches loyalty_tier_versions, which stays an immutable per-publish historical snapshot.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run + a real create/update/verify
-- cycle re-run immediately before the real apply; both functions confirmed live afterward).

-- A new parameter changes the signature, so CREATE OR REPLACE would leave the OLD 4-arg function
-- sitting alongside this one as an ambiguous overload (confirmed in the rolled-back dry run below,
-- same trap v343's own comment called out for business_create_reward_v326) -- drop it explicitly.
drop function if exists public.business_create_tier_v331(uuid,text,integer,numeric);
create or replace function public.business_create_tier_v331(
  p_business uuid, p_name text, p_threshold integer, p_multiplier numeric default 1,
  p_perk_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_perk_note text := nullif(btrim(coalesce(p_perk_note,'')),'');
  v_published uuid;
  v_open_draft uuid;
  v_sort integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)>120 then
    raise exception 'invalid tier name' using errcode='22023';
  end if;
  if p_threshold is null or p_threshold<0 then
    raise exception 'invalid tier threshold' using errcode='22023';
  end if;
  if p_multiplier is null or p_multiplier<1 then
    raise exception 'invalid tier multiplier' using errcode='22023';
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_tiers where business_id=p_business;
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,perk_note,sort)
  values (p_business,v_name,p_threshold,p_multiplier,v_perk_note,v_sort)
  returning * into v_tier;

  select active_config_version_id into v_published from public.businesses where id=p_business;
  if v_published is not null then
    insert into public.loyalty_tier_versions(tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
    values (v_tier.id,v_published,p_business,v_tier.name,v_tier.threshold,v_tier.points_multiplier,v_tier.perk_note,v_tier.sort,true)
    on conflict (tier_id,config_version_id) do nothing;
  end if;

  select id into v_open_draft from public.firm_config_versions
   where business_id=p_business and status='draft' limit 1;
  if v_open_draft is not null and v_open_draft is distinct from v_published then
    insert into public.loyalty_tier_versions(tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
    values (v_tier.id,v_open_draft,p_business,v_tier.name,v_tier.threshold,v_tier.points_multiplier,v_tier.perk_note,v_tier.sort,true)
    on conflict (tier_id,config_version_id) do nothing;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier.created','loyalty_tiers',v_tier.id,
    jsonb_build_object('name',v_name,'threshold',p_threshold,'points_multiplier',p_multiplier));

  return jsonb_build_object('status','ok','tier_id',v_tier.id,'name',v_tier.name,'threshold',v_tier.threshold,'perk_note',v_tier.perk_note);
end
$$;
revoke all privileges on function public.business_create_tier_v331(uuid,text,integer,numeric,text) from public, anon, authenticated;
grant execute on function public.business_create_tier_v331(uuid,text,integer,numeric,text) to authenticated;

create or replace function public.business_update_tier_v331(
  p_business uuid, p_tier uuid, p_name text, p_threshold integer,
  p_perk_note text default null, p_multiplier numeric default 1
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.loyalty_tiers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_perk_note text := nullif(btrim(coalesce(p_perk_note,'')),'');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)>120 then
    raise exception 'invalid tier name' using errcode='22023';
  end if;
  if p_threshold is null or p_threshold<0 then
    raise exception 'invalid tier threshold' using errcode='22023';
  end if;
  if p_multiplier is null or p_multiplier<1 then
    raise exception 'invalid tier multiplier' using errcode='22023';
  end if;
  select * into v_row from public.loyalty_tiers
   where id=p_tier and business_id=p_business and deleted_at is null
   for update;
  if not found then
    raise exception 'tier not found in this business' using errcode='42704';
  end if;
  update public.loyalty_tiers
     set name=v_name, threshold=p_threshold, points_multiplier=p_multiplier, perk_note=v_perk_note
   where id=p_tier and business_id=p_business;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier.updated','loyalty_tiers',p_tier,
    jsonb_build_object('name',v_name,'threshold',p_threshold,'points_multiplier',p_multiplier));
  return jsonb_build_object('status','ok','tier_id',p_tier,'name',v_name,'threshold',p_threshold,'perk_note',v_perk_note);
end
$$;
revoke all privileges on function public.business_update_tier_v331(uuid,uuid,text,integer,text,numeric) from public, anon, authenticated;
grant execute on function public.business_update_tier_v331(uuid,uuid,text,integer,text,numeric) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16, all 6 checks passed inside a rolled-back transaction against
-- gadpooereceldfpfxsod. Live loyalty_tiers confirmed unchanged after each rollback:
--   1. legacy 4-arg create call (no perk_note, exact old call shape) -> still succeeds.
--   2. create with perk_note -> loyalty_tiers.perk_note carries the value.
--   3. owner update (name/threshold/perk_note) -> all three values changed on the live row;
--      loyalty_tier_versions untouched (row count same before/after, inside the transaction).
--   4. non-owner staff update attempt -> refused with 42501, nothing changed.
--   5. p_threshold negative -> refused with 22023, nothing changed.
--   6. update on a deleted (deleted_at not null) tier -> refused with 42704.
