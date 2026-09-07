-- nestly_v814 — pausing a stamp gift stops paying out mid-card, exactly as deleting one did
-- before nestly_v805. Owner ruling, 2026-10-07: "pausing a stamp gift on a running stamps
-- programme follows the same rule as deleting one — the pause takes effect version-forward."
--
-- SYMPTOM, proven against production on 2026-10-07 inside a rolled-back transaction (a scratch
-- stamps tenant, one customer 4 stamps into a 5-stamp card, a "Free Coffee" gift at stamp 3, the
-- customer pinned to version 1 by app.stamp_cycle_version_v416):
--
--   rpc result             {"paused": true, "status": "ok", "reward_id": "5e995e8d-…"}
--   config versions        1          <- no version was published; nothing versioned forward
--   availability before    available_at_counter
--   availability after     ABSENT     <- app.reward_availability_v432
--   card milestones before 1
--   card milestones after  0          <- public.customer_get_stamp_card_v323
--   pinned redeem after    'reward is currently paused'   <- app.redeem_reward_core
--
-- Same customer, same card, same four stamps already collected. The owner switched one gift off
-- and it left the card in the customer's hand, the counter's list and the redeem path in the same
-- instant — the exact shape of F038, which nestly_v805 closed for DELETE and left open for PAUSE.
-- Rule 1, locked by the owner on 2026-08-22: once a customer starts a stamp card cycle, the
-- complete configuration for that cycle is immutable for that customer. Switching a gift off is a
-- configuration change like any other; it belongs to the NEXT card, not to the one in the hand.
--
-- WHY THIS IS NOT A ONE-LINE COPY OF v805. A withdrawal is expressed on the version row by
-- `active=false`, which every reader already honours through its own pinned-version join. `paused`
-- has no version row at all: public.loyalty_reward_versions carries no `paused` column, and
-- public.publish_loyalty_config's live-row sync deliberately never writes loyalty_rewards.paused.
-- Pause was, until now, a single global flag with no per-version truth to pin to.
--
-- Two shapes were considered and one rejected:
--
--   REJECTED — reuse the version row's `active` for a pause, marking the live row `paused_at` the
--   way v805 marks `withdrawn_at`. It works for the customer, but publish_loyalty_config's sync
--   (`active=rv.active`) would then drive loyalty_rewards.active to false for a merely PAUSED
--   gift. The owner's Rewards list, business_set_reward_paused_v326's own `and active` guard and
--   business_delete_reward_v326's would all stop seeing it: an owner who paused a gift could
--   never un-pause it, because the row they need is the row that vanished. A pause must leave the
--   catalogue intact.
--
--   CHOSEN — give the version row the state it was missing. public.loyalty_reward_versions gains
--   `paused`. The pause is written on the DRAFT's row and published through the v433 begin/commit
--   split, byte-for-byte the path business_update_reward_v326, business_set_stamp_card_length_v414
--   and (since v805) business_delete_reward_v326 take. loyalty_rewards.paused keeps meaning what
--   it always meant — what the owner sees, and what a POINTS gift is judged by. New cards pin to
--   the new version and never see the gift; open cards keep resolving the version they started
--   under, which still does; un-pausing publishes another version and the gift returns from the
--   next card. A card pinned to a version published DURING the pause carries paused=true on its
--   own row and does not get the gift back on un-pause, which a live-row-only marker could never
--   have expressed.
--
-- INHERITANCE, IN ONE PLACE. Three writers insert loyalty_reward_versions rows
-- (app.clone_reward_versions_for_config, public.ensure_published_reward_in_draft_v138,
-- public.save_loyalty_reward_draft) and none of them knows about `paused`. Left alone, the very
-- next unrelated stamp edit would clone a paused gift forward as un-paused and silently switch it
-- back on for every new card. Rather than teach three writers the same fact — and leave a fourth
-- to be written later without it — the column is NULLABLE-with-no-default and a BEFORE INSERT
-- trigger resolves NULL from the live row (`coalesce(live.paused,false)`), after which NOT NULL is
-- enforced. Every present and future writer inherits by omission; only this migration's writer
-- states a pause explicitly. That is v559's "a clone must inherit, never erase", enforced at the
-- table instead of asserted in each caller.
--
-- BACKFILL. Existing rows are set to the live row's current `paused`, which is precisely the
-- semantics every reader applied to them a moment ago — so the backfill changes no behaviour, and
-- omitting it would RESURRECT every currently paused stamp gift for any customer pinned to a
-- version that predates this migration (production carries 0 paused rewards of 50 today, so the
-- statement is a no-op there; it is written for the tenants and test clusters where it is not).
-- Both existing triggers on the table are suspended for the statement: the immutability guard
-- refuses UPDATEs on published version rows by design, and app.refresh_loyalty_config_snapshot_
-- trigger would rewrite every firm_config_versions.snapshot_hash — which is the optimistic-
-- concurrency token public.ensure_published_reward_in_draft_v138 compares a browser's held hash
-- against, so churning it here would answer an owner mid-edit with a spurious 40001.
--
-- ONE AUTHORITY FOR THE PREDICATE, a SIBLING of v805's rather than a second opinion:
-- app.reward_pause_on_offer_v814(live_paused, version_paused, is_stamp) is the single place that
-- says whose `paused` decides. For a stamp gift the customer's PINNED version row decides; for
-- everything else the live row does, exactly as today. All five readers call it, so the rule
-- cannot drift between the card, the counter, the customer's QR and the expiry sweep — the
-- disagreement nestly_v475 and nestly_v432 exist to prevent.
--
-- NO REFUSAL IS WEAKENED; ONE IS ADDED. public.business_set_stamp_card_length_v414 already
-- refuses to count a paused gift when it asks whether a gift sits past the end of the card, so a
-- paused gift is established as "not on the card". The final-stamp requirement had not been told:
-- both copies of it — the blocker in app.stamp_config_edit_commit_v433 and the raise in
-- public.publish_loyalty_config, which nestly_v564 requires to agree or a save raises mid-flight —
-- now ignore a paused version row. Pausing the last gift on the card therefore PENDS with
-- stamp_final_gift_missing and writes nothing, the way v805 made deleting it pend, instead of
-- leaving a live stamp card whose last stamp pays nothing.
--
-- SCOPE, deliberately narrow (v805's, restated):
--   * POINTS gifts are untouched. They carry no cycle pin, so a pause has nothing to be mid-way
--     through; the immediate branch below is what is running today plus the open-draft sync.
--   * A stamp gift on a stopped stamps programme, or a business that has never published, also
--     takes the immediate branch — the same predicate business_update_reward_v326 and
--     business_delete_reward_v326 use to decide whether to split.
--   * In the version-forward branch loyalty_rewards.paused is written only AFTER the commit
--     actually publishes. A pause that pends leaves the live row exactly as it was, so the owner's
--     list never claims a pause the customers' cards did not receive (v805's rule for the live
--     `active` flag, applied to `paused`).
--   * app.c45_base_actionable_wallet_card is knowingly left alone, for the reason v805 gives: it
--     resolves reward versions at businesses.active_config_version_id rather than at the cycle
--     pin, so the wallet hero already shows the wrong version after ANY stamp edit (register
--     F128). Fixing the hero's version resolution is F128's change; doing it here would put a
--     second pin authority in the tree.
--   * public.get_ci_reward_popularity_v1 is a catalogue-level owner report, not a customer offer,
--     and keeps reading the live flag.
--
-- COLUMN GRANT. public.loyalty_reward_versions carries column-level privileges, so a new column is
-- invisible to the API by default and any `select('*')` read would fail with "permission denied
-- for column". SELECT is granted; INSERT/UPDATE deliberately are not.
--
-- ALL READERS ARE SPLICED, not retyped (the nestly_v513 rule, the v542/v680/v805 method):
-- pg_get_functiondef + an anchor that must match exactly once, so a drifted body fails loudly
-- instead of being silently reverted to a stale copy.
--
-- REVERSIBLE: re-splice each anchor back (drop the app.reward_pause_on_offer_v814 call, restore
-- `not live.paused` / `if v_reward.paused then raise` / the un-qualified final-gift checks) and
-- re-apply the v326 pause body from
-- db/migrations/20260815_nestly_v326_points_gift_lifecycle.sql. The column and its default trigger
-- may stay; with no reader consulting the column it is inert.

begin;

set search_path to 'pg_catalog','public','app','pg_temp';

-- =============================================================================================
-- 1. THE VERSIONED STATE. A pause becomes a fact about a configuration version, not only about
--    the catalogue row.
-- =============================================================================================
alter table public.loyalty_reward_versions
  add column if not exists paused boolean;

comment on column public.loyalty_reward_versions.paused is
  'nestly_v814: was this gift switched off in THIS configuration version? A customer whose open '
  'stamp cycle is pinned to a version that says false keeps claiming the gift until that cycle '
  'ends, even while loyalty_rewards.paused is true. Never written directly by a clone: the '
  'BEFORE INSERT default below inherits it from the live row, so omitting it means "same as the '
  'catalogue says right now".';

grant select (paused) on public.loyalty_reward_versions to authenticated, service_role;

-- Inheritance in ONE place, for every writer that exists and every one not written yet. The
-- column has no DEFAULT on purpose: a DEFAULT would fill in false before this trigger runs and
-- make "the writer omitted it" indistinguishable from "the writer meant false".
create or replace function app.reward_version_paused_default_v814()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.paused is null then
    new.paused := coalesce((select live.paused from public.loyalty_rewards live
                             where live.id = new.reward_id
                               and live.business_id = new.business_id), false);
  end if;
  return new;
end
$$;

revoke all on function app.reward_version_paused_default_v814() from public, anon, authenticated;

drop trigger if exists trg_loyalty_reward_versions_paused_default_v814
  on public.loyalty_reward_versions;
create trigger trg_loyalty_reward_versions_paused_default_v814
before insert on public.loyalty_reward_versions
for each row execute function app.reward_version_paused_default_v814();

-- The backfill states today's semantics on yesterday's rows. See the header: the immutability
-- guard would refuse the published rows, and the snapshot trigger would churn the optimistic
-- concurrency token every open editor is holding.
alter table public.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_immutable;
alter table public.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_snapshot;

update public.loyalty_reward_versions rv
   set paused = coalesce(live.paused, false)
  from public.loyalty_rewards live
 where live.id = rv.reward_id
   and live.business_id = rv.business_id
   and rv.paused is null;

update public.loyalty_reward_versions set paused = false where paused is null;

alter table public.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_immutable;
alter table public.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_snapshot;

alter table public.loyalty_reward_versions alter column paused set not null;

-- =============================================================================================
-- 2. THE PREDICATE. The one authority on whose `paused` decides. Sibling of, not a rival to,
--    app.reward_live_on_offer_v805: that one answers "is this row still on offer at all", this
--    one answers "and is it switched on for the version the caller is asking about".
--    p_is_stamp mirrors app.reward_availability_v432's own `shape.is_stamp`.
-- =============================================================================================
create or replace function app.reward_pause_on_offer_v814(
  p_live_paused boolean, p_version_paused boolean, p_is_stamp boolean
) returns boolean
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select not coalesce(
    case when coalesce(p_is_stamp, false) then p_version_paused else p_live_paused end,
    false)
$$;

comment on function app.reward_pause_on_offer_v814(boolean, boolean, boolean) is
  'nestly_v814: is this gift switched ON for the caller''s version? For a stamp gift the pinned '
  'configuration version decides (nestly_v416: a customer mid-card keeps the deal they started '
  'under), so a pause reaches them only on their next card. For anything else the live row '
  'decides, exactly as before v814. A NULL version state means "not resolved yet" and defers - a '
  'caller that has not yet joined the pinned version passes NULL and asks again once it has.';

revoke all on function app.reward_pause_on_offer_v814(boolean, boolean, boolean)
  from public, anon, authenticated;

-- =============================================================================================
-- 3. THE WRITER. Restated in full — both branches must be readable side by side. The immediate
--    branch is the v326 body plus the open-draft sync business_delete_reward_v326 already does.
-- =============================================================================================
create or replace function public.business_set_reward_paused_v326(
  p_business uuid, p_reward uuid, p_paused boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_row public.loyalty_rewards%rowtype;
  v_draft_version uuid;
  v_active_version uuid;
  v_is_stamp boolean := false;
  v_target uuid;
  v_split boolean := false;
  v_published boolean := true;
  v_commit jsonb := jsonb_build_object('publish_status','published');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  select * into v_row from public.loyalty_rewards
   where id=p_reward and business_id=p_business and active
   for update;
  if not found then
    raise exception 'gift not found in this business' using errcode='42704';
  end if;

  if v_row.paused is not distinct from p_paused then
    -- Unchanged: no write, no version, no audit row — the pre-v814 no-op, kept verbatim.
    return jsonb_build_object('status','ok','reward_id',p_reward,'paused',p_paused,
      'mode','unchanged','version_split',false,
      'publish_status','published','blockers','[]'::jsonb);
  end if;

  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  -- nestly_v814: the same question business_update_reward_v326 and business_delete_reward_v326
  -- ask before they split.
  v_is_stamp := exists (
    select 1 from public.business_programmes spine
     where spine.id = v_row.programme_id and spine.business_id = p_business
       and spine.kind = 'stamps' and spine.active);

  if v_is_stamp and v_active_version is not null then
    v_target := app.stamp_config_edit_begin_v433(p_business);
    v_split := (v_target is distinct from v_active_version);
  else
    v_target := v_active_version;
  end if;

  if v_split and not exists (
       select 1 from public.loyalty_reward_versions
        where reward_id=p_reward and business_id=p_business and config_version_id=v_target) then
    -- The draft carries no row for this gift (it exists live but not in the version the draft was
    -- cloned from), so version-forwarding it would publish a version that does not mention it and
    -- change nothing. Fall back to the immediate write rather than report a split that did not
    -- happen. Same fallback business_delete_reward_v326 takes for the same reason.
    v_split := false;
  end if;

  if v_split then
    update public.loyalty_reward_versions set paused=p_paused
     where reward_id=p_reward and business_id=p_business and config_version_id=v_target;
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
    v_published := coalesce(v_commit->>'publish_status','published') = 'published';
    -- The LIVE row moves only once the new version is actually live. publish_loyalty_config's
    -- live-row sync deliberately never writes `paused`, so this is the write that keeps the
    -- owner's list and the customers' new cards saying the same thing — and a PENDING pause
    -- leaves the gift exactly as it was, on the list and on every card.
    if v_published then
      update public.loyalty_rewards set paused=p_paused
       where id=p_reward and business_id=p_business;
    end if;
  else
    update public.loyalty_rewards set paused=p_paused
     where id=p_reward and business_id=p_business;

    -- Keep any currently OPEN draft's own version row in sync so that publishing an unrelated
    -- draft later cannot revert this pause for a customer pinned to it. A *published* version row
    -- cannot be touched here (trg_loyalty_reward_versions_immutable) and must not be: it is the
    -- promise an open card was started under.
    select id into v_draft_version from public.firm_config_versions
     where business_id=p_business and status='draft' limit 1;
    if v_draft_version is not null then
      update public.loyalty_reward_versions set paused=p_paused
       where reward_id=p_reward and business_id=p_business
         and config_version_id=v_draft_version;
    end if;
  end if;

  if v_published then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business,auth.uid(),
      case when p_paused then 'reward.paused' else 'reward.unpaused' end,
      'loyalty_rewards',p_reward,
      jsonb_build_object('name',coalesce(v_row.customer_name,v_row.name),
        'version_split',v_split,
        'target_version_id',v_target,
        'publish_status',coalesce(v_commit->>'publish_status','published')));
  else
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business,auth.uid(),'reward.pause_pending','loyalty_rewards',p_reward,
      jsonb_build_object('name',coalesce(v_row.customer_name,v_row.name),
        'requested_paused',p_paused,
        'target_version_id',v_target,
        'blockers',coalesce(v_commit->'blockers','[]'::jsonb)));
  end if;

  return jsonb_build_object('status','ok','reward_id',p_reward,
    'paused', case when v_published then p_paused else v_row.paused end,
    'mode', case when not v_published then 'pending'
                 when v_split then 'version_forward' else 'immediate' end,
    'version_split', v_split,
    'publish_status', coalesce(v_commit->>'publish_status','published'),
    'blockers', coalesce(v_commit->'blockers','[]'::jsonb));
end
$function$;

revoke all on function public.business_set_reward_paused_v326(uuid, uuid, boolean) from public, anon;
grant execute on function public.business_set_reward_paused_v326(uuid, uuid, boolean) to authenticated;
grant execute on function public.business_set_reward_paused_v326(uuid, uuid, boolean) to service_role;

comment on function public.business_set_reward_paused_v326(uuid, uuid, boolean) is
  'v814: switch a gift on or off. A stamp gift on a running stamp programme changes state '
  'VERSION-FORWARD (v433 begin/commit): the new state is published as the next configuration '
  'version, and a customer whose open cycle is pinned to an earlier version keeps the gift until '
  'that cycle ends. Un-pausing publishes it again from the next card. Publishing runs the full '
  'stamps validation, so switching the last gift off the card pends with blockers and writes '
  'nothing. Anything else — a points gift, a stopped stamps programme, a business that has never '
  'published — takes effect immediately, exactly as before.';

-- =============================================================================================
-- 4. THE REFUSAL. Both copies of the final-stamp requirement stop counting a paused gift, so
--    switching the last gift off pends the way deleting it does. v564 requires the two to agree.
-- =============================================================================================

-- 4a. app.stamp_config_edit_commit_v433 — the owner-language blocker.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'      if not exists (select 1 from public.loyalty_reward_versions rv
                       join public.business_programmes spine on spine.id = rv.programme_id
                      where rv.config_version_id = p_version and rv.business_id = p_business
                        and rv.active and spine.kind = ''stamps''
                        and rv.cost_points = v_eff_target) then';
  v_inject constant text :=
'      if not exists (select 1 from public.loyalty_reward_versions rv
                       join public.business_programmes spine on spine.id = rv.programme_id
                      where rv.config_version_id = p_version and rv.business_id = p_business
                        and rv.active and spine.kind = ''stamps''
                        and not coalesce(rv.paused, false)
                        and rv.cost_points = v_eff_target) then';
begin
  v_def := pg_get_functiondef('app.stamp_config_edit_commit_v433(uuid,uuid)'::regprocedure);
  if position('coalesce(rv.paused, false)' in v_def) > 0 then
    raise notice 'nestly_v814: stamp_config_edit_commit_v433 already ignores a paused gift, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v814: anchor did not match exactly once in stamp_config_edit_commit_v433 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.stamp_config_edit_commit_v433(uuid,uuid)
  from public, anon, authenticated;

-- 4b. public.publish_loyalty_config — the raise the blocker exists to keep the owner away from.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind=''stamps'' and rv.cost_points=v_eff_target) then';
  v_inject constant text :=
'    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind=''stamps'' and not coalesce(rv.paused,false) and rv.cost_points=v_eff_target) then';
begin
  v_def := pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure);
  if position('not coalesce(rv.paused,false)' in v_def) > 0 then
    raise notice 'nestly_v814: publish_loyalty_config already ignores a paused gift, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v814: anchor did not match exactly once in publish_loyalty_config — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;

-- =============================================================================================
-- 5. THE READERS. Spliced with anchors reproduced inside their replacements. Each one already
--    joins the reward VERSION row at the customer's pin; all they lacked was permission to
--    believe it about `paused`.
-- =============================================================================================

-- 5a. app.reward_availability_v432 — the ONE availability core (staff list == customer list).
--     Arm 0's live-row join gives up `not live.paused` to the WHERE clause, where `shape` and
--     `rv` are both in scope; on an INNER JOIN that is the same query. Arm 1 (survivors from a
--     closed cycle) already has `rv` above the join and changes in place.
do $splice$
declare
  v_def text; v_new text;
  v_arm0_join constant text :=
'      join public.loyalty_rewards live
        on live.business_id = business.id
       and not live.paused';
  v_arm0_join_new constant text :=
'      join public.loyalty_rewards live
        on live.business_id = business.id';
  v_arm0_where constant text :=
'      where app.reward_live_on_offer_v805(live.active, live.withdrawn_at, shape.is_stamp)
        and live.programme_id is not null';
  v_arm0_where_new constant text :=
'      where app.reward_live_on_offer_v805(live.active, live.withdrawn_at, shape.is_stamp)
        and app.reward_pause_on_offer_v814(live.paused, rv.paused, shape.is_stamp)
        and live.programme_id is not null';
  v_arm1 constant text :=
'       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and not live.paused';
  v_arm1_new constant text :=
'       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and app.reward_pause_on_offer_v814(live.paused, rv.paused, true)';
begin
  v_def := pg_get_functiondef(
    'app.reward_availability_v432(uuid,uuid,timestamptz)'::regprocedure);
  if position('reward_pause_on_offer_v814' in v_def) > 0 then
    raise notice 'nestly_v814: reward_availability_v432 already asks the v814 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_arm0_join, ''))) / nullif(length(v_arm0_join),0) <> 1
       or (length(v_def) - length(replace(v_def, v_arm0_where, ''))) / nullif(length(v_arm0_where),0) <> 1
       or (length(v_def) - length(replace(v_def, v_arm1, ''))) / nullif(length(v_arm1),0) <> 1 then
      raise exception 'nestly_v814: an anchor did not match exactly once in reward_availability_v432 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_arm0_join, v_arm0_join_new);
    v_new := replace(v_new, v_arm0_where, v_arm0_where_new);
    v_new := replace(v_new, v_arm1, v_arm1_new);
    if v_new = v_def then
      raise exception 'nestly_v814: splice produced no change in reward_availability_v432'
        using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.reward_availability_v432(uuid,uuid,timestamptz)
  from public, anon, authenticated;

-- 5b. app.redeem_reward_core — the counter. The live-row veto fires before the pinned version is
--     resolved, so it becomes stamps-permissive there and the real decision moves down to where
--     v_version is known: for a points gift both checks read the live row and agree, for a stamp
--     gift only the pinned version's own state can answer.
do $splice$
declare
  v_def text; v_new text;
  v_early constant text :=
'  if v_reward.paused then raise exception ''reward is currently paused'' using errcode=''22023''; end if;';
  v_early_new constant text :=
'  if not app.reward_pause_on_offer_v814(v_reward.paused, null::boolean,
       exists (select 1 from public.business_programmes spine
                where spine.id = v_reward.programme_id and spine.business_id = p_business
                  and spine.kind = ''stamps'')) then
    raise exception ''reward is currently paused'' using errcode=''22023''; end if;';
  v_late constant text :=
'  if v_version.id is null or not v_version.active then raise exception ''reward not found or inactive''; end if;';
  v_late_new constant text :=
'  if v_version.id is null or not v_version.active then raise exception ''reward not found or inactive''; end if;
  if not app.reward_pause_on_offer_v814(v_reward.paused, v_version.paused,
       v_programme_kind = ''stamps'') then
    raise exception ''reward is currently paused'' using errcode=''22023''; end if;';
begin
  v_def := pg_get_functiondef(
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure);
  if position('reward_pause_on_offer_v814' in v_def) > 0 then
    raise notice 'nestly_v814: redeem_reward_core already asks the v814 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_early, ''))) / nullif(length(v_early),0) <> 1
       or (length(v_def) - length(replace(v_def, v_late, ''))) / nullif(length(v_late),0) <> 1 then
      raise exception 'nestly_v814: an anchor did not match exactly once in redeem_reward_core — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_early, v_early_new);
    v_new := replace(v_new, v_late, v_late_new);
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;

-- 5c. public.customer_get_stamp_card_v323 — the card the customer is holding. nestly_v475 added
--     this live-row test so the card could not promise what the counter refuses; the counter now
--     honours a paused gift on a pinned cycle, so the card must keep showing it.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'                      and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
                      and not coalesce(live.paused, false))';
  v_inject constant text :=
'                      and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
                      and app.reward_pause_on_offer_v814(live.paused, rv.paused, true))';
begin
  v_def := pg_get_functiondef('public.customer_get_stamp_card_v323(text)'::regprocedure);
  if position('reward_pause_on_offer_v814' in v_def) > 0 then
    raise notice 'nestly_v814: customer_get_stamp_card_v323 already asks the v814 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v814: anchor did not match exactly once in customer_get_stamp_card_v323 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

-- 5d. public.customer_create_redemption_intent_v89 — the customer's own QR. The live-row test is
--     taken first, before the version is known, so it defers for a stamp gift and the pinned
--     version's state is asked immediately after the version row is in hand.
do $splice$
declare
  v_def text; v_new text;
  v_live constant text :=
'    where reward.id=p_reward and reward.business_id=p_business and not reward.paused
      and app.reward_live_on_offer_v805(reward.active, reward.withdrawn_at,';
  v_live_new constant text :=
'    where reward.id=p_reward and reward.business_id=p_business
      and app.reward_pause_on_offer_v814(reward.paused, null::boolean,
            exists (select 1 from public.business_programmes spine
                     where spine.id=reward.programme_id and spine.business_id=p_business
                       and spine.kind=''stamps''))
      and app.reward_live_on_offer_v805(reward.active, reward.withdrawn_at,';
  v_ver constant text :=
'    if not found
       or (v_reward_version.claim_available_from is not null
         and v_reward_version.claim_available_from>now())
       or (v_reward_version.claim_available_until is not null
         and v_reward_version.claim_available_until<=now()) then
      raise exception ''reward is unavailable'' using errcode=''22023'';
    end if;';
  v_ver_new constant text :=
'    if not found
       or (v_reward_version.claim_available_from is not null
         and v_reward_version.claim_available_from>now())
       or (v_reward_version.claim_available_until is not null
         and v_reward_version.claim_available_until<=now()) then
      raise exception ''reward is unavailable'' using errcode=''22023'';
    end if;
    if not app.reward_pause_on_offer_v814(v_reward.paused, v_reward_version.paused,
         exists (select 1 from public.business_programmes spine
                  where spine.id=v_reward.programme_id and spine.business_id=p_business
                    and spine.kind=''stamps'')) then
      raise exception ''reward is unavailable'' using errcode=''22023'';
    end if;';
begin
  v_def := pg_get_functiondef(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  if position('reward_pause_on_offer_v814' in v_def) > 0 then
    raise notice 'nestly_v814: customer_create_redemption_intent_v89 already asks the v814 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_live, ''))) / nullif(length(v_live),0) <> 1
       or (length(v_def) - length(replace(v_def, v_ver, ''))) / nullif(length(v_ver),0) <> 1 then
      raise exception 'nestly_v814: an anchor did not match exactly once in customer_create_redemption_intent_v89 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_live, v_live_new);
    v_new := replace(v_new, v_ver, v_ver_new);
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  to authenticated, service_role;

-- 5e. app.stamp_reward_expire_due_v464 — a gift that is still claimable must still be able to
--     expire. Leaving this reader behind would make a paused-but-pinned gift the one reward on
--     the card the expiry sweep can never record.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and not live.paused';
  v_inject constant text :=
'       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and app.reward_pause_on_offer_v814(live.paused, rv.paused, true)';
begin
  v_def := pg_get_functiondef('app.stamp_reward_expire_due_v464(uuid,uuid,uuid)'::regprocedure);
  if position('reward_pause_on_offer_v814' in v_def) > 0 then
    raise notice 'nestly_v814: stamp_reward_expire_due_v464 already asks the v814 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v814: anchor did not match exactly once in stamp_reward_expire_due_v464 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.stamp_reward_expire_due_v464(uuid,uuid,uuid)
  from public, anon, authenticated;

-- =============================================================================================
-- 6. Prove the change took, in the transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_missing text[] := '{}';
  v_name text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='loyalty_reward_versions'
                    and column_name='paused' and is_nullable='NO') then
    raise exception 'nestly_v814: loyalty_reward_versions.paused was not created NOT NULL'
      using errcode='XX001';
  end if;
  if exists (select 1 from public.loyalty_reward_versions rv
              join public.loyalty_rewards live
                on live.id=rv.reward_id and live.business_id=rv.business_id
             where rv.paused is distinct from coalesce(live.paused,false)) then
    raise exception 'nestly_v814: the backfill left a version row disagreeing with its live row — a pause would resurrect or vanish'
      using errcode='XX001';
  end if;
  if not exists (select 1 from information_schema.column_privileges
                  where table_schema='public' and table_name='loyalty_reward_versions'
                    and column_name='paused' and grantee='authenticated'
                    and privilege_type='SELECT') then
    raise exception 'nestly_v814: authenticated cannot SELECT loyalty_reward_versions.paused'
      using errcode='XX001';
  end if;
  if not exists (select 1 from pg_trigger t
                  where t.tgrelid='public.loyalty_reward_versions'::regclass
                    and t.tgname='trg_loyalty_reward_versions_paused_default_v814'
                    and not t.tgisinternal) then
    raise exception 'nestly_v814: version rows have no paused-inheritance default — the next clone would switch a paused gift back on'
      using errcode='XX001';
  end if;
  if exists (select 1 from pg_trigger t
              where t.tgrelid='public.loyalty_reward_versions'::regclass
                and t.tgname in ('trg_loyalty_reward_versions_immutable',
                                 'trg_loyalty_reward_versions_snapshot')
                and t.tgenabled = 'D') then
    raise exception 'nestly_v814: a trigger suspended for the backfill was left disabled'
      using errcode='XX001';
  end if;
  foreach v_name in array array[
    'app.reward_availability_v432(uuid,uuid,timestamptz)',
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
    'public.customer_get_stamp_card_v323(text)',
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
    'app.stamp_reward_expire_due_v464(uuid,uuid,uuid)'
  ] loop
    if position('reward_pause_on_offer_v814' in pg_get_functiondef(v_name::regprocedure)) = 0 then
      v_missing := v_missing || v_name;
    end if;
  end loop;
  if array_length(v_missing,1) > 0 then
    raise exception 'nestly_v814: these readers still gate on the live paused flag alone: %',
      array_to_string(v_missing,', ') using errcode='XX001';
  end if;
  if position('stamp_config_edit_begin_v433' in pg_get_functiondef(
       'public.business_set_reward_paused_v326(uuid,uuid,boolean)'::regprocedure)) = 0 then
    raise exception 'nestly_v814: pausing a stamp gift still does not version forward'
      using errcode='XX001';
  end if;
  if position('coalesce(rv.paused, false)' in pg_get_functiondef(
       'app.stamp_config_edit_commit_v433(uuid,uuid)'::regprocedure)) = 0
     or position('not coalesce(rv.paused,false)' in pg_get_functiondef(
       'public.publish_loyalty_config(uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v814: the final-stamp requirement still counts a paused gift — switching the last gift off would leave a card that pays nothing'
      using errcode='XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema='app' and routine_name='reward_pause_on_offer_v814'
                and grantee in ('anon','authenticated','PUBLIC')) then
    raise exception 'nestly_v814: the predicate is reachable from the API' using errcode='XX001';
  end if;
end
$verify$;

commit;
