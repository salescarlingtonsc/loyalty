-- nestly_v679 — a tier edit must survive the next publish.
--
-- THE BUG (audit finding F087, P1, CONFIRMED against production).
--
-- Manage Tiers is an IMMEDIATE-WRITE surface, exactly like the tier basis was before
-- nestly_v586. public.business_update_tier_v331 (rename / reached-at threshold / multiplier /
-- perk wording) and public.business_set_tier_benefits_v365 (which re-derives perk_note through
-- app.v365_apply_perk_note) write public.loyalty_tiers and nothing else. They never touch
-- public.loyalty_tier_versions.
--
-- But a draft is born as a CLONE, and the tier half of that clone was still being copied out of
-- the base version's snapshot:
--
--   insert into public.loyalty_tier_versions(...)
--   select tier_id,v_id,business_id,name,threshold,points_multiplier,perk_note,sort,active,
--          effective_from,expires_at
--     from public.loyalty_tier_versions where config_version_id=v_base;
--
-- — in BOTH draft creators (public.create_loyalty_config_draft, nestly_v565, and
-- public.create_grow_config_draft_v138, nestly_v564). nestly_v564 had already fixed the
-- PROGRAMME row of that same clone to read `coalesce(live.X, base.X)` off the live
-- public.loyalty_programs row, for precisely this reason; the tier rows three statements later
-- were left reading history.
--
-- publish_loyalty_config then writes the live ladder back out of the draft:
--
--   insert into public.loyalty_tiers(...) select ... from public.loyalty_tier_versions
--    where config_version_id=p_version and ... and active
--   on conflict (id) do update set name=excluded.name, threshold=excluded.threshold,
--     points_multiplier=excluded.points_multiplier, perk_note=excluded.perk_note, ...
--
-- so the FIRST unrelated loyalty save after a tier edit — a birthday gift
-- (business_save_birthday_program_v424 opens a draft and publishes it in one transaction), a
-- bring-back campaign, a reward edit, a wizard step, app.stamp_config_edit_commit_v433,
-- public.set_studio_rule_active — silently snapped the ladder back to whatever it was at the
-- last publish. Success toast for the thing the owner DID touch; no warning about the thing
-- they did not. Thresholds and multipliers going back means customers are re-bucketed and earn
-- at the old rate, so this is a change to loyalty economics, not a cosmetic one.
--
-- Proven in production: business 709387ff (Jess Salon) created Gold at 300, re-thresholded it
-- to 2 and Diamond 500 -> 5 through Manage Tiers, and 73 seconds later a birthday_editor_v424
-- publish based on version 1 wrote 300 and 500 straight back over them. The owner re-entered the
-- same two edits the next morning. Three further tenants are sitting in the same armed state
-- right now (live values that diverge from their own published snapshot).
--
-- public.business_create_tier_v331 was never affected, because it already syncs a new tier
-- FORWARD into the active version and into an open draft. That is the pattern this migration
-- generalises.
--
-- THE FIX — two independent guards, one authority each.
--
-- 1. app.v679_clone_tiers_into_draft() is now the single place a draft's tier rows come from,
--    called by both draft creators. It clones the LIVE public.loyalty_tiers values (name,
--    threshold, points_multiplier, perk_note, sort, effective_from, expires_at) and keeps the
--    base snapshot only as the fallback for a tier the live table no longer carries — the same
--    "a draft is a clone of what is LIVE" rule nestly_v564 wrote for the programme row.
--    perk_note / effective_from / expires_at are nullable and clearing them is a real edit, so
--    they are taken from the live row whenever a live row exists rather than coalesced (a
--    coalesce would resurrect a note the owner deleted).
--    A live tier that the base version does not carry at all is added to the draft as well:
--    publish DELETEs any live tier the published version omits, so leaving it out of the clone
--    would have that publish destroy a tier the owner can see.
--    `active` is deliberately still taken from the base row. It is the flag publish reads to
--    decide whether a tier survives, and a soft-deleted tier must stay soft-deleted, not become
--    a hard DELETE that cascades into tier_benefits_v365 (the destruction nestly_v577 removed).
--    Deletion was never part of this bug: publish's conflict-update omits paused / deleted_at,
--    so a tier deleted through business_delete_tier_v331 stays deleted across a publish.
--
-- 2. app.v679_sync_tier_into_open_drafts() carries a live tier edit forward into every OPEN
--    DRAFT, called from business_update_tier_v331 and from app.v365_apply_perk_note (the
--    perk_note authority, whose only caller is business_set_tier_benefits_v365). Guard 1 alone
--    is not enough: create_grow_config_draft_v138 REPLAYS an already-open draft instead of
--    re-cloning, and a draft opened before the tier edit would still carry the old values.
--    Published versions are left alone on purpose — they are immutable snapshots
--    (app.loyalty_tier_version_guard refuses any UPDATE outside a draft), nothing reads them
--    once guard 1 makes every new draft follow live, and rewriting history to fix a
--    forward-looking setting is the wrong trade. This is the shape nestly_v586 used for
--    tier_basis.
--
-- NO ONE-TIME REPAIR of already-open drafts, deliberately, and unlike nestly_v586.
-- public.loyalty_tiers has no updated_at, so there is no way to tell an open draft that is
-- STALE (cloned before a Manage Tiers edit) from one that holds a DELIBERATE in-progress tier
-- edit made through save_loyalty_tier_draft_v143 in the setup wizard. Overwriting the second
-- kind would be this same bug pointed the other way. The armed tenants are closed regardless:
-- their next draft is cloned from live by guard 1, and their next tier edit is carried forward
-- by guard 2.
--
-- Touches loyalty configuration: run `npm run tenant-gate` and `npm run certify-tenant` after
-- applying.
--
-- Acceptance: db/tests/v679_tier_edits_survive_publish.sql (rollback-only, run as the owner).

begin;

-- ============================================================================================
-- GUARD 1 — a draft's tier rows are a clone of what is LIVE.
-- ============================================================================================
create or replace function app.v679_clone_tiers_into_draft(p_business uuid, p_base uuid, p_draft uuid)
returns integer
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows integer;
begin
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  )
  select q.tier_id,q.config_version_id,q.business_id,q.name,q.threshold,q.points_multiplier,
         q.perk_note,q.sort,q.active,q.effective_from,q.expires_at
  from (
    -- Every tier the base version carries, at its LIVE values where it still exists.
    select base.tier_id                                       as tier_id,
           p_draft                                            as config_version_id,
           base.business_id                                   as business_id,
           coalesce(live.name, base.name)                     as name,
           coalesce(live.threshold, base.threshold)           as threshold,
           coalesce(live.points_multiplier, base.points_multiplier) as points_multiplier,
           case when live.id is null then base.perk_note else live.perk_note end as perk_note,
           coalesce(live.sort, base.sort)                     as sort,
           base.active                                        as active,
           case when live.id is null then base.effective_from else live.effective_from end as effective_from,
           case when live.id is null then base.expires_at else live.expires_at end as expires_at
      from public.loyalty_tier_versions base
      left join public.loyalty_tiers live
        on live.id = base.tier_id and live.business_id = base.business_id
     where base.config_version_id = p_base
       and base.business_id = p_business
    union all
    -- A live tier the base version never captured. Without this row the publish that follows
    -- would delete it outright.
    select live.id, p_draft, live.business_id, live.name, live.threshold,
           live.points_multiplier, live.perk_note, live.sort, true,
           live.effective_from, live.expires_at
      from public.loyalty_tiers live
     where live.business_id = p_business
       and live.deleted_at is null
       and not exists (
         select 1 from public.loyalty_tier_versions base
          where base.config_version_id = p_base and base.tier_id = live.id)
  ) q
  on conflict (tier_id,config_version_id) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows;
end $$;
revoke all privileges on function app.v679_clone_tiers_into_draft(uuid,uuid,uuid) from public, anon, authenticated;

-- ============================================================================================
-- GUARD 2 — an immediate tier edit reaches every draft that is already open.
-- ============================================================================================
create or replace function app.v679_sync_tier_into_open_drafts(p_business uuid, p_tier uuid)
returns integer
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_live public.loyalty_tiers%rowtype;
  v_rows integer := 0;
  v_added integer := 0;
begin
  select * into v_live from public.loyalty_tiers
   where id = p_tier and business_id = p_business;
  if not found then return 0; end if;

  -- Only draft rows are written. app.loyalty_tier_version_guard refuses everything else, and
  -- history is meant to stay history.
  update public.loyalty_tier_versions v
     set name              = v_live.name,
         threshold         = v_live.threshold,
         points_multiplier = v_live.points_multiplier,
         perk_note         = v_live.perk_note,
         sort              = v_live.sort,
         effective_from    = v_live.effective_from,
         expires_at        = v_live.expires_at
    from public.firm_config_versions f
   where f.id = v.config_version_id
     and f.status = 'draft'
     and f.business_id = p_business
     and v.business_id = p_business
     and v.tier_id = p_tier;
  get diagnostics v_rows = row_count;

  if v_live.deleted_at is null then
    insert into public.loyalty_tier_versions(
      tier_id,config_version_id,business_id,name,threshold,points_multiplier,
      perk_note,sort,active,effective_from,expires_at
    )
    select p_tier,f.id,p_business,v_live.name,v_live.threshold,v_live.points_multiplier,
           v_live.perk_note,v_live.sort,true,v_live.effective_from,v_live.expires_at
      from public.firm_config_versions f
     where f.business_id = p_business
       and f.status = 'draft'
       and not exists (
         select 1 from public.loyalty_tier_versions v
          where v.config_version_id = f.id and v.tier_id = p_tier)
    on conflict (tier_id,config_version_id) do nothing;
    get diagnostics v_added = row_count;
    v_rows := v_rows + v_added;
  end if;
  return v_rows;
end $$;
revoke all privileges on function app.v679_sync_tier_into_open_drafts(uuid,uuid) from public, anon, authenticated;

-- ============================================================================================
-- The two draft creators now share guard 1. Everything else in both is verbatim from the live
-- production definition (nestly_v565 and nestly_v564 respectively).
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.create_loyalty_config_draft(p_business uuid, p_based_on uuid DEFAULT NULL::uuid, p_source text DEFAULT 'manual'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_id uuid;
  v_no integer;
  v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.businesses where id=p_business for update;
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  select * into v_typed from public.loyalty_program_versions
  where config_version_id=v_base and business_id=p_business;
  if not found then
    -- nestly_v565: 'base configuration not found' was the dead end every tenant born without a
    -- loyalty_programs row hit -- it could never open Grow, because the first thing Grow does is
    -- ask for a draft and there was nothing to base one on. Give the business the row it should
    -- have been born with; app.seed_loyalty_config_version then publishes version 1 (v507, "born
    -- live"), and the base resolves on the retry below. Only a base that is STILL missing raises.
    perform app.ensure_loyalty_program_row(p_business, 'draft_bootstrap');
    v_base:=coalesce(
      p_based_on,
      app.active_config_version(p_business),
      (select current_config_version_id from public.loyalty_programs where business_id=p_business)
    );
    select * into v_typed from public.loyalty_program_versions
    where config_version_id=v_base and business_id=p_business;
    if not found then raise exception 'base configuration not found'; end if;
  end if;
  select coalesce(max(version_no),0)+1 into v_no
  from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,
    coalesce(nullif(btrim(p_source),''),'manual'),
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days,
    stamp_reward_expiry_days
  )
  -- (merged nestly_v564 + nestly_v565: bootstrap above, clone-from-live below -- both
  --  migrations replace this function; this v565 copy is derived FROM v564's so the later
  --  apply cannot undo the earlier one.)
  -- nestly_v564: a draft is a clone of what is LIVE, not of the version it is based on. The
  -- base version is a historical snapshot; the live public.loyalty_programs row is what the
  -- counter, the customer app and the earn engine actually read. Cloning the snapshot is how a
  -- stale draft became a time machine: open the editor, publish something else, then save the
  -- first draft and the live row is rewritten from a version that is weeks old. The base row is
  -- kept only as the fallback for a column the live row has never held a value for.
  select v_id, base.business_id,
    coalesce(live.kind,base.kind),
    coalesce(live.loyalty_model,base.loyalty_model),
    coalesce(live.active,base.active),
    coalesce(live.earn_points_per_dollar,base.earn_points_per_dollar),
    coalesce(live.redeem_points,base.redeem_points),
    coalesce(live.reward_credit_cents,base.reward_credit_cents),
    coalesce(live.stamp_target,base.stamp_target),
    coalesce(live.stamp_per_cents,base.stamp_per_cents),
    coalesce(live.tier_basis,base.tier_basis),
    coalesce(live.expiry_mode,base.expiry_mode),
    coalesce(live.expiry_days,base.expiry_days),
    coalesce(live.stamp_validity_days,base.stamp_validity_days),
    coalesce(live.stamp_reward_expiry_days,base.stamp_reward_expiry_days)
  from public.loyalty_program_versions base
  left join public.loyalty_programs live on live.business_id=base.business_id
  where base.config_version_id=v_base and base.business_id=p_business;
  -- nestly_v679: the TIER rows follow live for the same reason the programme row above does.
  perform app.v679_clone_tiers_into_draft(p_business, v_base, v_id);
  perform app.refresh_loyalty_config_snapshot(v_id);
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end
$function$;
revoke all privileges on function public.create_loyalty_config_draft(uuid,uuid,text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_grow_config_draft_v138(p_business uuid, p_based_on uuid DEFAULT NULL::uuid, p_source text DEFAULT 'grow_shared_edit'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_existing public.firm_config_versions%rowtype;
  v_typed public.loyalty_program_versions%rowtype;
  v_id uuid;
  v_no integer;
  v_snapshot_hash text;
begin
  if v_actor is null or not app.is_salon_owner(p_business)
     or not (
       app.can_module_write(p_business,'loyalty')
       or app.can_module_write(p_business,'retention')
     ) then
    raise exception 'owner Grow configuration access required' using errcode='42501';
  end if;
  if p_source not in ('grow_shared_edit','grow_retention_edit','grow_reward_edit') then
    raise exception 'invalid Grow draft source' using errcode='22023';
  end if;

  perform 1 from public.businesses where id=p_business for update;
  if not found then
    raise exception 'business is unavailable' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v138:grow-draft:'||p_business::text,0));
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  if v_base is null or not exists(
    select 1 from public.firm_config_versions
     where id=v_base and business_id=p_business and status='published'
  ) then
    raise exception 'published base configuration not found' using errcode='22023';
  end if;

  select * into v_existing from public.firm_config_versions
   where business_id=p_business and based_on_version_id=v_base and status='draft'
   order by version_no desc limit 1 for update;
  if found then
    return jsonb_build_object(
      'version_id',v_existing.id,'version_no',v_existing.version_no,
      'status','draft','snapshot_hash',v_existing.snapshot_hash,
      'replayed',true,'published',false
    );
  end if;

  select * into v_typed from public.loyalty_program_versions
   where config_version_id=v_base and business_id=p_business;
  if not found then
    raise exception 'base Loyalty configuration not found' using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_no
    from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,p_source,
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  perform set_config('app.v138_grow_draft_id',v_id::text,true);
  perform set_config('app.v138_grow_draft_actor',v_actor::text,true);
  -- nestly_v564: all THIRTEEN typed columns, seeded from the LIVE programme row. This insert
  -- named eleven -- stamp_validity_days and stamp_reward_expiry_days were simply absent, so a
  -- Grow draft was born with NULLs in them and publish copied those NULLs straight over a live
  -- card's stamp validity and gift expiry. (publish now coalesces those two as well, so the
  -- erasure is closed from both ends.) The clone follows LIVE, not the base snapshot, for the
  -- same reason create_loyalty_config_draft does.
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days,
    stamp_validity_days,stamp_reward_expiry_days
  ) select
    v_id, base.business_id,
    coalesce(live.kind,base.kind),
    coalesce(live.loyalty_model,base.loyalty_model),
    coalesce(live.active,base.active),
    coalesce(live.earn_points_per_dollar,base.earn_points_per_dollar),
    coalesce(live.redeem_points,base.redeem_points),
    coalesce(live.reward_credit_cents,base.reward_credit_cents),
    coalesce(live.stamp_target,base.stamp_target),
    coalesce(live.stamp_per_cents,base.stamp_per_cents),
    coalesce(live.tier_basis,base.tier_basis),
    coalesce(live.expiry_mode,base.expiry_mode),
    coalesce(live.expiry_days,base.expiry_days),
    coalesce(live.stamp_validity_days,base.stamp_validity_days),
    coalesce(live.stamp_reward_expiry_days,base.stamp_reward_expiry_days)
  from public.loyalty_program_versions base
  left join public.loyalty_programs live on live.business_id=base.business_id
  where base.config_version_id=v_base and base.business_id=p_business;
  perform set_config('app.v138_grow_draft_id','',true);
  perform set_config('app.v138_grow_draft_actor','',true);
  -- nestly_v679: the tier rows follow live, through the same helper create_loyalty_config_draft
  -- uses. This also stops a Grow draft dropping effective_from / expires_at, which the insert
  -- this replaces never named at all -- publish would then write those NULLs over a live tier's
  -- window.
  perform app.v679_clone_tiers_into_draft(p_business, v_base, v_id);
  perform app.refresh_loyalty_config_snapshot(v_id);
  select snapshot_hash into v_snapshot_hash
    from public.firm_config_versions where id=v_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'CREATE_GROW_DRAFT','firm_config_versions',v_id,
    jsonb_build_object('based_on_version_id',v_base,'source',p_source,'published',false));
  return jsonb_build_object(
    'version_id',v_id,'version_no',v_no,'status','draft',
    'snapshot_hash',v_snapshot_hash,'replayed',false,'published',false
  );
end $function$;
revoke all privileges on function public.create_grow_config_draft_v138(uuid,uuid,text) from public, anon;
grant execute on function public.create_grow_config_draft_v138(uuid,uuid,text) to authenticated, service_role;

-- ============================================================================================
-- The two immediate-write tier paths now carry the edit forward. Bodies verbatim from live
-- apart from the single nestly_v679 line each.
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.business_update_tier_v331(p_business uuid, p_tier uuid, p_name text, p_threshold integer, p_perk_note text DEFAULT NULL::text, p_multiplier numeric DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row public.loyalty_tiers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_perk_note text := nullif(btrim(coalesce(p_perk_note,'')),'');
  v_drafts integer := 0;
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
  -- nestly_v679: and every OPEN DRAFT, or the next publish restores what the owner just replaced.
  v_drafts := app.v679_sync_tier_into_open_drafts(p_business, p_tier);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier.updated','loyalty_tiers',p_tier,
    jsonb_build_object('name',v_name,'threshold',p_threshold,'points_multiplier',p_multiplier,
      'drafts_realigned',v_drafts));
  return jsonb_build_object('status','ok','tier_id',p_tier,'name',v_name,'threshold',p_threshold,'perk_note',v_perk_note);
end
$function$;
revoke all privileges on function public.business_update_tier_v331(uuid,uuid,text,integer,text,numeric) from public, anon;
grant execute on function public.business_update_tier_v331(uuid,uuid,text,integer,text,numeric) to authenticated, service_role;

-- The perk_note authority. business_set_tier_benefits_v365 is its only caller, so putting the
-- forward-sync here covers benefit edits without restating that 200-line function.
CREATE OR REPLACE FUNCTION app.v365_apply_perk_note(p_business uuid, p_tier uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  update public.loyalty_tiers t
     set perk_note = nullif((
       select string_agg(app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period), E'\n' order by b.sort, b.created_at, b.id)
         from public.tier_benefits_v365 b
        where b.business_id=p_business and b.tier_id=p_tier and b.deleted_at is null and b.active),'')
   where t.id=p_tier and t.business_id=p_business;
  -- nestly_v679: the derived perk wording is a live-only write like every other Manage Tiers
  -- edit, so it has to reach any open draft too.
  perform app.v679_sync_tier_into_open_drafts(p_business, p_tier);
end $function$;
revoke all privileges on function app.v365_apply_perk_note(uuid,uuid) from public, anon, authenticated;

commit;
