-- nestly_v675 — a stale stamp-edit draft is retired, never handed back (audit finding F035, P1).
--
-- THE DEFECT. nestly_v433 gave every stamp-card editor one path: begin (reuse the pending
-- stamp-edit draft, or clone the active version) → apply → commit (publish, or report blockers
-- and leave the draft standing). Leaving the draft standing is deliberate and load-bearing:
-- growing a 10-stamp card to 12 cannot publish until a gift sits at stamp 12, so that half of
-- the change PENDS on an open draft until the other half arrives.
--
-- app.stamp_config_edit_begin_v433 reuses that draft on the strength of its source tag alone:
--
--     select id into v_target from public.firm_config_versions
--      where business_id = p_business and status = 'draft' and source = 'stamp_edit_split_v433'
--      order by version_no desc limit 1;
--     if v_target is not null then return v_target; end if;
--
-- It never asks what the draft was based on. nestly_v564 later taught public.publish_loyalty_config
-- to refuse a draft that is behind — a draft cloned from version N, left open while someone
-- published N+1, does not merge, it time-machines — with
--
--     raise exception 'stale_draft: this draft was based on an older version of your setup —
--       open the editor again and re-apply the change' using errcode='23514';
--
-- Put the two together and a tenant can be wedged for good. One stamp change pends (draft D,
-- based on active A). ANY other surface publishes B — the setup wizard's Go-live,
-- business_save_birthday_program_v424, business_delete_retention_program_v332,
-- set_studio_rule_active, app.sync_business_programmes_v308, a second tab. Nothing supersedes,
-- rebases or discards D: 'stamp_edit_split_v433' appears in exactly one function in the whole
-- database (begin), publish supersedes only the prior PUBLISHED version, no job sweeps the
-- table, and firm_config_versions carries SELECT-only RLS so no client can retire it either.
-- From then on every stamp-card RPC — business_set_stamp_card_length_v414,
-- business_create_reward_v326, business_update_reward_v326, business_set_earning_rule_v359 —
-- goes begin → D → commit → publish → stale_draft → the whole save rolls back. The literal
-- on-screen advice, "open the editor again and re-apply the change", is the one thing that
-- cannot work: reopening re-selects D. Only a database-side fix cleared it.
--
-- (While D is still incomplete, commit returns 'pending' instead, so the fault hides until the
-- tenant finishes their card and the draft finally becomes publishable.)
--
-- THE FIX. A pending draft is a half-finished edit, not a promise. It is only meaningful
-- against the configuration it was cloned from; once that configuration has been replaced, the
-- half-edit cannot be published and must be thrown away rather than handed back forever.
-- So begin now reuses a draft ONLY when its based_on_version_id IS the business's current
-- active_config_version_id. Anything else is retired to 'abandoned' — the lifecycle's own word
-- for a thrown-away draft that was never activated (firm_config_versions_status_check since
-- frenly_v26; app.ps1c2_effect_state reads it as "a thrown-away draft; never activated") — and
-- a fresh draft is cloned from the active version. The owner's next edit therefore lands on
-- today's configuration and publishes; the abandoned half-edit is recorded in audit_log rather
-- than deleted, so what was dropped is still answerable.
--
-- Nothing here needs an immutability bypass. The v433/v423 guards
-- (app.loyalty_version_immutable_guard and its app.v433_program_edit_version_id /
-- app.v423_reward_edit_version_id tokens) sit on the version CHILD rows
-- (loyalty_program_versions, loyalty_reward_versions); this migration only moves the
-- firm_config_versions header's status, whose sole BEFORE UPDATE OF status trigger
-- (trg_v145_config_publish_guard) fires only on a transition INTO 'published'.
--
-- BACKFILL. The estate is repaired by this migration, not by waiting for each owner to trip
-- over it: every open 'stamp_edit_split_v433' draft that is already behind its business's
-- pointer is abandoned here, with the same audit row. It is replay-safe — a second apply finds
-- nothing left in status 'draft' — and it deliberately never touches a draft that IS the
-- pointer (the pre-v507 seeded version-1 shape, which is the current state by definition).
-- Production holds one such tenant today: business 709387ff (jess-salon), split draft
-- version_no 2 based on version 1 while the pointer is version 3.

begin;

-- ============================================================================================
-- §1  RETIRE THE STALE HALF-EDITS — one authority, used by begin AND by the backfill below.
-- ============================================================================================
create or replace function app.stamp_config_abandon_stale_drafts_v675(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_active uuid;
  v_n integer := 0;
begin
  select active_config_version_id into v_active
    from public.businesses where id = p_business;
  -- A business that has never published has no pointer to be behind.
  if v_active is null then
    return 0;
  end if;
  with stale as (
    update public.firm_config_versions fcv
       set status = 'abandoned'
     where fcv.business_id = p_business
       and fcv.status = 'draft'
       and fcv.source = 'stamp_edit_split_v433'
       -- Never the pointer itself: a draft that IS active is the current state, not a laggard.
       and fcv.id is distinct from v_active
       and fcv.based_on_version_id is distinct from v_active
    returning fcv.id, fcv.version_no, fcv.based_on_version_id
  ), logged as (
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    select p_business, auth.uid(), 'stamp_edit_draft.abandoned_stale',
           'firm_config_versions', stale.id,
           jsonb_build_object(
             'source', 'stamp_config_abandon_stale_drafts_v675',
             'version_no', stale.version_no,
             'based_on_version_id', stale.based_on_version_id,
             'active_config_version_id', v_active,
             'reason', 'the configuration this half-finished stamp edit was cloned from has been replaced')
      from stale
    returning 1
  )
  select count(*) into v_n from logged;
  return v_n;
end;
$$;

-- ============================================================================================
-- §2  BEGIN — reuse only a draft that is based on TODAY'S configuration.
--
--     Everything else about this function is nestly_v433 unchanged: the same active-version
--     precondition and message, the same source tag, the same clone through
--     public.create_loyalty_config_draft (which since nestly_v564 clones the LIVE loyalty
--     programme row, so a length or spend already written live is carried into the fresh draft
--     rather than lost with the abandoned one).
-- ============================================================================================
create or replace function app.stamp_config_edit_begin_v433(p_business uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_active uuid;
  v_target uuid;
  v_based_on uuid;
  v_draft json;
begin
  select active_config_version_id into v_active from public.businesses where id = p_business;
  if v_active is null then
    raise exception 'this business has no published loyalty configuration yet' using errcode = 'XX001';
  end if;
  select id, based_on_version_id into v_target, v_based_on
    from public.firm_config_versions
   where business_id = p_business and status = 'draft' and source = 'stamp_edit_split_v433'
   order by version_no desc limit 1;
  if v_target is not null then
    -- nestly_v675 (audit F035): the pending half-edit is reusable only against the version it
    -- was cloned from. Once the business is serving a different version, publish_loyalty_config
    -- will refuse this draft forever ('stale_draft', 23514) — so handing it back is what wedged
    -- the tenant. Retire it and clone a fresh one instead.
    if v_based_on is not distinct from v_active then
      return v_target;
    end if;
    perform app.stamp_config_abandon_stale_drafts_v675(p_business);
  end if;
  v_draft := public.create_loyalty_config_draft(p_business, v_active, 'stamp_edit_split_v433');
  return (v_draft ->> 'version_id')::uuid;
end;
$$;

-- ============================================================================================
-- §3  ONE-OFF ESTATE REPAIR — replay-safe. Every tenant already wedged is unwedged here.
-- ============================================================================================
do $v675_backfill$
declare
  v_business uuid;
  v_repaired integer := 0;
  v_total integer := 0;
begin
  for v_business in
    select distinct fcv.business_id
      from public.firm_config_versions fcv
      join public.businesses b on b.id = fcv.business_id
     where fcv.status = 'draft'
       and fcv.source = 'stamp_edit_split_v433'
       and b.active_config_version_id is not null
       and fcv.id is distinct from b.active_config_version_id
       and fcv.based_on_version_id is distinct from b.active_config_version_id
  loop
    v_repaired := app.stamp_config_abandon_stale_drafts_v675(v_business);
    v_total := v_total + v_repaired;
    raise notice 'nestly_v675: business % — % stale stamp-edit draft(s) abandoned', v_business, v_repaired;
  end loop;
  raise notice 'nestly_v675: % stale stamp-edit draft(s) abandoned estate-wide', v_total;
end
$v675_backfill$;

-- ============================================================================================
-- §4  ACLS — restated for every function this migration creates or replaces (preflight rule).
--     Both are internal helpers on the edit path; the owner-facing RPCs that call them
--     (business_set_stamp_card_length_v414, business_create_reward_v326,
--     business_update_reward_v326, business_set_earning_rule_v359) keep their own grants,
--     which this migration does not touch.
-- ============================================================================================
revoke all on function app.stamp_config_edit_begin_v433(uuid) from public, anon, authenticated;
revoke all on function app.stamp_config_abandon_stale_drafts_v675(uuid) from public, anon, authenticated;

commit;
