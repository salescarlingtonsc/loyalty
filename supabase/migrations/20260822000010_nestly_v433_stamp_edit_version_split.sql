-- nestly_v433 — a merchant edit never rewrites a customer's stamp card (P0 from the
-- 2026-08-22 real-business simulation; owner rules 1, 2 and 14, locked 2026-08-22).
--
-- THE DEFECT, proven live on the QA tenant: the Stamp Card page's day-to-day editors
-- (business_update_reward_v326 / business_create_reward_v326) mutate the ACTIVE published
-- configuration version in place — the very version every open stamp card is pinned to
-- (app.stamp_cycle_version_v416). Renaming "Free Upsize"@5 to "Free Espresso Shot"@7 removed a
-- customer's already-claimable earned gift from their live card, mid-collection. The two other
-- stamp controls (card length v414, spend-per-stamp v359) wrote only the mutable
-- loyalty_programs row, which the pinned readers treat as a fallback — so they confirmed
-- "saved" while changing nothing the engine reads.
--
-- THE RULE (owner): once a customer starts a stamp card cycle, the complete configuration for
-- that cycle is immutable for that customer. A merchant edit clones the active version, applies
-- the change to the clone, and publishes the clone. Open cards keep resolving the version they
-- started under (v416's published_at ordering already does this); new cards start on the newest
-- version. Multiple edits before anyone starts a new card coalesce into one new version, so a
-- customer completing card A moves straight to the latest C, never through an obsolete B.
--
-- THE MECHANISM. Peekaa already owns a full-fidelity version cloner: create_loyalty_config_draft
-- copies the programme + tier version rows, and the AFTER INSERT triggers on firm_config_versions
-- (clone_reward_versions_for_config, c45_clone_birthday_programs_on_draft,
-- clone_retention_program_versions_on_draft, clone_program_rules_on_draft,
-- clone_loyalty_branch_overrides_on_draft) carry rewards + eligibility scopes, birthday, retention,
-- program rules and branch overrides. publish_loyalty_config owns every publish invariant
-- (one-published-per-business, supersede, live-row sync, v331 tier carry, v431 spine model,
-- validation guards, audit). v433 composes exactly those two:
--
--   EVERY stamp-affecting edit = begin (reuse the pending stamp-edit draft, or clone the active
--   version) → apply the edit to the DRAFT → commit (publish when the draft is a valid stamp
--   card; otherwise report blockers and leave the draft standing for the next edit).
--
-- The pend-instead-of-raise commit is load-bearing: "make the card 6 stamps" cannot publish
-- until a gift sits at stamp 6, and "move the gift to stamp 6" cannot publish while the card is
-- 5 long — with an eager publish the owner deadlocks in either order; with the pending draft
-- each half lands and the pair goes live together. Because commit PUBLISHES, every completed
-- mid-life edit passes the same stamps validation a Go-live does. The programme-row token
-- carve-out (§3) remains for the points-side earning-rule editor, where version rows carry no
-- pin and an in-place correction of the active version is the right shape.
--
-- (§1's open-card risk probe is retained as an advisory reader — e.g. for editor copy — but the
-- edit path no longer branches on it: version-forward is unconditional for stamp edits.)

begin;

-- ============================================================================================
-- §1  WHEN MUST AN EDIT SPLIT?
-- ============================================================================================
create or replace function app.stamp_open_card_risk_v433(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1
      from public.businesses b
      join public.firm_config_versions fcv on fcv.id = b.active_config_version_id
      join public.business_programmes spine
        on spine.business_id = b.id and spine.kind = 'stamps' and spine.active
     where b.id = p_business
       and exists (
         select 1 from public.points_ledger pl
          where pl.business_id = b.id
            and pl.programme_id = spine.id
            and pl.points > 0
            and pl.created_at >= coalesce(fcv.published_at, fcv.created_at)
       )
  )
$$;

-- ============================================================================================
-- §2  BEGIN / COMMIT — the one edit path every stamp editor uses.
--
--     Every stamp-affecting edit lands on a DRAFT cloned from the active version (rule 2
--     verbatim: clone → version forward → publish); the open card's version is never written.
--     Successive edits REUSE the same pending draft, and commit publishes only when the draft
--     is a valid stamp card — otherwise it reports what is missing and leaves the draft
--     standing. This is what makes a two-part change possible at all: "make the card 6 stamps"
--     is unpublishable until a gift sits at stamp 6, and "put a gift at stamp 6" is
--     unpublishable while the card is 5 long — each half pends, the pair publishes. An eager
--     publish on every half would deadlock the owner in either order.
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
  v_draft json;
begin
  select active_config_version_id into v_active from public.businesses where id = p_business;
  if v_active is null then
    raise exception 'this business has no published loyalty configuration yet' using errcode = 'XX001';
  end if;
  select id into v_target from public.firm_config_versions
   where business_id = p_business and status = 'draft' and source = 'stamp_edit_split_v433'
   order by version_no desc limit 1;
  if v_target is not null then
    return v_target;
  end if;
  v_draft := public.create_loyalty_config_draft(p_business, v_active, 'stamp_edit_split_v433');
  return (v_draft ->> 'version_id')::uuid;
end;
$$;

create or replace function app.stamp_config_edit_commit_v433(p_business uuid, p_version uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_typed public.loyalty_program_versions%rowtype;
  v_blockers jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from public.firm_config_versions
                  where id = p_version and business_id = p_business and status = 'draft') then
    return jsonb_build_object('publish_status', 'published', 'published_version_id', p_version);
  end if;
  select * into v_typed from public.loyalty_program_versions
   where config_version_id = p_version and business_id = p_business;
  -- The same shape rules publish_loyalty_config enforces, checked FIRST so an incomplete
  -- two-part edit pends with owner-language guidance instead of raising mid-save.
  if v_typed.loyalty_model = 'stamps' then
    if coalesce(v_typed.stamp_per_cents, 0) <= 0 then
      v_blockers := v_blockers || jsonb_build_object(
        'code', 'stamp_spend_missing',
        'message', 'set how much a customer spends for 1 stamp to finish this change');
    end if;
    if coalesce(v_typed.stamp_target, 0) <= 0 then
      v_blockers := v_blockers || jsonb_build_object(
        'code', 'stamp_length_missing',
        'message', 'set how many stamps the card has to finish this change');
    else
      if exists (select 1 from public.loyalty_reward_versions rv
                   join public.business_programmes spine on spine.id = rv.programme_id
                  where rv.config_version_id = p_version and rv.business_id = p_business
                    and rv.active and spine.kind = 'stamps'
                    and rv.cost_points > v_typed.stamp_target) then
        v_blockers := v_blockers || jsonb_build_object(
          'code', 'stamp_gift_past_end',
          'message', format('a gift sits past stamp %s — move or remove it to finish this change', v_typed.stamp_target));
      end if;
      if not exists (select 1 from public.loyalty_reward_versions rv
                       join public.business_programmes spine on spine.id = rv.programme_id
                      where rv.config_version_id = p_version and rv.business_id = p_business
                        and rv.active and spine.kind = 'stamps'
                        and rv.cost_points = v_typed.stamp_target) then
        v_blockers := v_blockers || jsonb_build_object(
          'code', 'stamp_final_gift_missing',
          'message', format('add a gift at stamp %s to finish this change', v_typed.stamp_target));
      end if;
    end if;
  end if;
  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('publish_status', 'pending',
      'draft_version_id', p_version, 'blockers', v_blockers);
  end if;
  perform public.publish_loyalty_config(p_version);
  return jsonb_build_object('publish_status', 'published', 'published_version_id', p_version);
end;
$$;

-- ============================================================================================
-- §3  PROGRAMME-ROW CARVE-OUT — the no-split path may correct the ACTIVE version's stamp
--     numbers (today those writes went only to the mutable live row, which is why the card
--     length and spend-per-stamp controls confirmed "saved" while the engine kept the old
--     values). Same shape as v423's reward-row carve-out: a transaction token naming the exact
--     version, and an allow-list of columns — anything else on a published row stays immutable.
-- ============================================================================================
create or replace function app.loyalty_version_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_status text;
  -- nestly_v433: the earning/card-shape columns the owner's stamp and earning-rule editors own.
  -- stamp_validity_days is listed ahead of the column landing (nestly_v435) so this guard does
  -- not need a third restatement.
  v_owner_editable constant text[] := array[
    'stamp_target','stamp_per_cents','stamp_validity_days',
    'earn_points_per_dollar','expiry_mode','expiry_days'];
begin
  if tg_op = 'DELETE' then
    raise exception 'configuration versions are append-only' using errcode='restrict_violation';
  end if;
  select status into v_status from public.firm_config_versions
   where id = old.config_version_id;
  if v_status <> 'draft' then
    if tg_op = 'UPDATE'
       and nullif(current_setting('app.v433_program_edit_version_id', true), '') = old.config_version_id::text
       and (to_jsonb(new) - v_owner_editable) = (to_jsonb(old) - v_owner_editable) then
      return new;
    end if;
    raise exception 'published configuration rows are immutable' using errcode='restrict_violation';
  end if;
  return new;
end;
$$;

-- ============================================================================================
-- §4  UPDATE A GIFT — stamp gifts version forward; points gifts keep v423's owner-ruled
--     immediate sync (the catalogue is live-mutable by design there).
-- ============================================================================================
create or replace function public.business_update_reward_v326(
  p_business uuid,
  p_reward uuid,
  p_name text,
  p_points integer,
  p_description text default null::text,
  p_credit_cents integer default 0,
  p_image_ref text default null::text,
  p_clear_image boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_row public.loyalty_rewards%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_description text := nullif(btrim(coalesce(p_description,'')),'');
  v_image_ref text;
  v_credit_cents integer := coalesce(p_credit_cents,0);
  v_active_version uuid;
  v_is_stamp boolean := false;
  v_target uuid;
  v_split boolean := false;
  v_published public.loyalty_reward_versions%rowtype;
  v_published_synced boolean := false;
  v_drafts_synced integer := 0;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
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

  v_image_ref := case when p_clear_image then null
                      when p_image_ref is not null then p_image_ref
                      else v_row.image_ref end;

  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  -- nestly_v433: is this a stamp-card gift on the running stamp programme? Those edits must not
  -- touch the version open cards are pinned to.
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

  update public.loyalty_rewards
     set name=v_name, internal_name=v_name, customer_name=v_name,
         description=v_description, cost_points=p_points,
         credit_cents=v_credit_cents, estimated_cost_cents=v_credit_cents,
         image_ref=v_image_ref
   where id=p_reward and business_id=p_business;

  if v_active_version is not null then
    -- The pre-edit published row: in split mode it stays byte-identical for the pinned cards and
    -- is only read here as the stale-draft comparison baseline; in no-split mode it is the row
    -- being edited (v423's token carve-out).
    select * into v_published from public.loyalty_reward_versions
     where reward_id=p_reward and business_id=p_business
       and config_version_id=v_active_version
     for update;

    if found then
      if v_split then
        update public.loyalty_reward_versions
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref
         where reward_id=p_reward and business_id=p_business
           and config_version_id=v_target;
      else
        perform set_config('app.v423_reward_edit_version_id', v_published.id::text, true);
        update public.loyalty_reward_versions
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref
         where id=v_published.id;
        perform set_config('app.v423_reward_edit_version_id', '', true);
      end if;
      v_published_synced := true;

      -- v423: bring stale draft clones along (a draft whose values already diverged is staged
      -- work and is not touched). The split draft is excluded by name — it already holds the
      -- new values.
      with resynced as (
        update public.loyalty_reward_versions draft
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref
         where draft.reward_id=p_reward
           and draft.business_id=p_business
           and draft.config_version_id<>v_active_version
           and draft.config_version_id is distinct from v_target
           and exists (select 1 from public.firm_config_versions fcv
                        where fcv.id=draft.config_version_id
                          and fcv.business_id=p_business
                          and fcv.status='draft')
           and draft.internal_name is not distinct from v_published.internal_name
           and draft.customer_name is not distinct from v_published.customer_name
           and draft.description is not distinct from v_published.description
           and draft.cost_points is not distinct from v_published.cost_points
           and draft.credit_cents is not distinct from v_published.credit_cents
           and draft.estimated_cost_cents is not distinct from v_published.estimated_cost_cents
           and draft.image_ref is not distinct from v_published.image_ref
        returning 1)
      select count(*)::integer into v_drafts_synced from resynced;
    end if;
  end if;

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.updated','loyalty_rewards',p_reward,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',v_credit_cents,
      'published_version_synced',v_published_synced,
      'active_config_version_id',v_active_version,
      'draft_versions_synced',v_drafts_synced,
      'version_split',v_split,'target_version_id',v_target,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',v_credit_cents,
    'published_version_synced',v_published_synced,
    'version_split',v_split,'target_version_id',v_target)
    || v_commit;
end
$function$;

-- ============================================================================================
-- §5  CREATE A GIFT — a stamp gift added mid-life lands on a NEW version, so it appears on new
--     cards only (v416's ruling); a points gift keeps landing on the active catalogue.
-- ============================================================================================
create or replace function public.business_create_reward_v326(
  p_business uuid, p_programme uuid, p_name text, p_points integer,
  p_credit_cents integer default 0, p_description text default null::text,
  p_image_ref text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_reward_id uuid:=gen_random_uuid();
  v_name text:=nullif(btrim(coalesce(p_name,'')),'');
  v_description text:=nullif(btrim(coalesce(p_description,'')),'');
  v_kind text:=case when coalesce(p_credit_cents,0)>0 then 'credit' else 'manual_item' end;
  v_active_version uuid;
  v_is_stamp boolean := false;
  v_target uuid;
  v_split boolean := false;
  v_sort integer;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
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

  v_is_stamp := exists (
    select 1 from public.business_programmes spine
     where spine.id = p_programme and spine.business_id = p_business
       and spine.kind = 'stamps' and spine.active);

  if v_is_stamp then
    v_target := app.stamp_config_edit_begin_v433(p_business);
    v_split := (v_target is distinct from v_active_version);
  else
    v_target := v_active_version;
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_rewards where business_id=p_business;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,description,image_ref,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_description,p_image_ref,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target
  );

  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,image_ref,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id
  ) values(
    v_reward_id,p_business,v_target,v_name,v_name,v_description,p_image_ref,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme
  );

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
      'version_split',v_split,'target_version_id',v_target,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
    'version_split',v_split,'target_version_id',v_target)
    || v_commit;
end
$function$;

-- ============================================================================================
-- §6  CARD LENGTH — writes the version row the engine actually reads (the live row stays as a
--     display mirror), splitting first whenever an open card could be pinned to it.
-- ============================================================================================
create or replace function public.business_set_stamp_card_length_v414(p_business uuid, p_stamps integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_spine uuid;
  v_blocker record;
  v_active_version uuid;
  v_target uuid;
  v_split boolean := false;
  v_row public.loyalty_programs%rowtype;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_stamps is null or p_stamps < 1 or p_stamps > 100 then
    raise exception 'a stamp card must be between 1 and 100 stamps long' using errcode='22023';
  end if;

  select id into v_spine from public.business_programmes
   where business_id = p_business and kind = 'stamps';
  if v_spine is null then
    raise exception 'this business is not running a stamp card' using errcode='XX001';
  end if;

  select active_config_version_id into v_active_version
    from public.businesses where id = p_business;
  if v_active_version is null then
    raise exception 'this business has no published loyalty configuration yet' using errcode='XX001';
  end if;

  v_target := app.stamp_config_edit_begin_v433(p_business);
  v_split := (v_target is distinct from v_active_version);

  -- The same redeemability test app.redeem_reward_core applies, asked against the version this
  -- edit will actually publish.
  select rv.customer_name as name, rv.cost_points as stamps into v_blocker
    from public.loyalty_reward_versions rv
    join public.loyalty_rewards r on r.id = rv.reward_id
   where rv.business_id = p_business
     and rv.config_version_id = v_target
     and rv.programme_id = v_spine
     and coalesce(rv.active, true)
     and coalesce(r.active, true)
     and not coalesce(r.paused, false)
     and rv.cost_points > p_stamps
   order by rv.cost_points desc
   limit 1;
  if found then
    raise exception '% needs % stamps, so a % stamp card would put it out of reach. Move or remove that gift first.',
      coalesce(v_blocker.name,'A gift'), v_blocker.stamps, p_stamps
      using errcode='23514';
  end if;

  if v_split then
    update public.loyalty_program_versions
       set stamp_target = p_stamps
     where config_version_id = v_target and business_id = p_business;
  else
    perform set_config('app.v433_program_edit_version_id', v_target::text, true);
    update public.loyalty_program_versions
       set stamp_target = p_stamps
     where config_version_id = v_target and business_id = p_business;
    perform set_config('app.v433_program_edit_version_id', '', true);
  end if;

  update public.loyalty_programs
     set stamp_target = p_stamps
   where business_id = p_business
  returning * into v_row;
  if not found then
    raise exception 'this business has no loyalty programme row' using errcode='XX001';
  end if;

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'stamp_card.length_set', 'loyalty_programs', p_business,
    jsonb_build_object('stamp_target', v_row.stamp_target,
      'version_split', v_split, 'target_version_id', v_target,
      'publish_status', v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','stamp_target', v_row.stamp_target,
    'version_split', v_split, 'target_version_id', v_target)
    || v_commit;
end $function$;

-- ============================================================================================
-- §7  EARNING RULE — the spend-per-stamp / points-rate / points-expiry editor now writes the
--     version row the earn path reads (its live-row write was inert against the engine), with
--     the stamp split when an open card could be pinned. Points expiry stays a POINTS policy;
--     existing batches keep the expiry they were stamped with at earn (owner rule 8).
-- ============================================================================================
create or replace function public.business_set_earning_rule_v359(
  p_business uuid,
  p_earn_points_per_dollar numeric default null::numeric,
  p_stamp_per_cents integer default null::integer,
  p_expiry_mode text default null::text,
  p_expiry_days integer default null::integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_mode text := nullif(btrim(coalesce(p_expiry_mode,'')),'');
  v_days integer;
  v_row public.loyalty_programs%rowtype;
  v_active_version uuid;
  v_stamps_active boolean;
  v_target uuid;
  v_split boolean := false;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;

  if p_earn_points_per_dollar is not null and p_earn_points_per_dollar <= 0 then
    raise exception 'points per dollar must be greater than zero' using errcode='22023';
  end if;
  if p_stamp_per_cents is not null and p_stamp_per_cents <= 0 then
    raise exception 'spend per stamp must be greater than zero' using errcode='22023';
  end if;

  if v_mode is not null then
    if v_mode not in ('none','fixed','inactivity') then
      raise exception 'invalid expiry mode' using errcode='22023';
    end if;
    if v_mode = 'none' then
      v_days := null;
    else
      v_days := p_expiry_days;
      if v_days is null or v_days < 1 or v_days > 3650 then
        raise exception 'expiry days must be between 1 and 3650' using errcode='22023';
      end if;
    end if;
  end if;

  insert into public.loyalty_programs(business_id, active, configuration_status,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days)
  values (p_business, false, 'draft',
    coalesce(p_earn_points_per_dollar, 1), p_stamp_per_cents,
    coalesce(v_mode, 'none'), v_days)
  on conflict (business_id) do update set
    -- NB: must test the PARAMETER, not `excluded`. The INSERT arm defaults an omitted rate to 1,
    -- so `excluded.earn_points_per_dollar` is never null and a coalesce here would silently reset
    -- a firm's real rate to 1 on any call that only meant to change the stamp rate or expiry.
    earn_points_per_dollar = case when p_earn_points_per_dollar is null then public.loyalty_programs.earn_points_per_dollar else excluded.earn_points_per_dollar end,
    stamp_per_cents        = case when p_stamp_per_cents is null then public.loyalty_programs.stamp_per_cents else excluded.stamp_per_cents end,
    expiry_mode            = case when v_mode is null then public.loyalty_programs.expiry_mode else excluded.expiry_mode end,
    expiry_days            = case when v_mode is null then public.loyalty_programs.expiry_days else excluded.expiry_days end
  returning * into v_row;

  -- nestly_v433: the engine reads the VERSION row (resolve_loyalty_branch_config on the earn
  -- path, the pinned readers everywhere else), so the rule must land there too. Stamps running
  -- and customers mid-card → version forward; otherwise the active version is corrected in
  -- place through the token carve-out.
  select b.active_config_version_id into v_active_version
    from public.businesses b where b.id = p_business;
  if v_active_version is not null then
    v_stamps_active := exists (
      select 1 from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = 'stamps' and spine.active);
    if v_stamps_active then
      v_target := app.stamp_config_edit_begin_v433(p_business);
      v_split := (v_target is distinct from v_active_version);
    else
      v_target := v_active_version;
    end if;

    if v_split then
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end
       where config_version_id = v_target and business_id = p_business;
    else
      perform set_config('app.v433_program_edit_version_id', v_target::text, true);
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end
       where config_version_id = v_target and business_id = p_business;
      perform set_config('app.v433_program_edit_version_id', '', true);
    end if;

    if v_split then
      v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
    end if;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'earning_rule.updated', 'loyalty_programs', p_business,
    jsonb_build_object('earn_points_per_dollar', v_row.earn_points_per_dollar,
                       'stamp_per_cents', v_row.stamp_per_cents,
                       'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
                       'version_split', v_split, 'target_version_id', v_target,
                       'publish_status', v_commit->>'publish_status'));

  return jsonb_build_object('status','ok',
    'earn_points_per_dollar', v_row.earn_points_per_dollar,
    'stamp_per_cents', v_row.stamp_per_cents,
    'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
    'version_split', v_split, 'target_version_id', v_target)
    || v_commit;
end
$function$;

-- ============================================================================================
-- §8  ACLS — restated for every function this migration touches (preflight rule)
-- ============================================================================================
revoke all on function app.stamp_open_card_risk_v433(uuid) from public, anon, authenticated;
revoke all on function app.stamp_config_edit_begin_v433(uuid) from public, anon, authenticated;
revoke all on function app.stamp_config_edit_commit_v433(uuid, uuid) from public, anon, authenticated;
revoke all on function app.loyalty_version_immutable_guard() from public, anon, authenticated;

revoke all on function public.business_update_reward_v326(uuid, uuid, text, integer, text, integer, text, boolean) from public, anon;
grant execute on function public.business_update_reward_v326(uuid, uuid, text, integer, text, integer, text, boolean) to authenticated, service_role;
revoke all on function public.business_create_reward_v326(uuid, uuid, text, integer, integer, text, text) from public, anon;
grant execute on function public.business_create_reward_v326(uuid, uuid, text, integer, integer, text, text) to authenticated, service_role;
revoke all on function public.business_set_stamp_card_length_v414(uuid, integer) from public, anon;
grant execute on function public.business_set_stamp_card_length_v414(uuid, integer) to authenticated, service_role;
revoke all on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer) from public, anon;
grant execute on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer) to authenticated, service_role;

commit;
