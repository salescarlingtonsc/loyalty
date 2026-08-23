-- nestly_v472 — a gift can be given an end date, and a business can publish a menu.
--
-- OWNER, batch 11 (2026-08-23), two marks on two screens.
--
-- (1) "Allow to add expiry date for each rewards and display in customer view", written across the
--     Point system gift list. Asked which clock they meant, the owner chose the OFFERING window —
--     a wall-clock date after which the gift is no longer offered — not a per-gift countdown that
--     starts when a customer earns it. Asked what the customer should see, the owner wrote:
--     "they should see the expiry of each gift, example free lotion will expiry on 21 September
--     2026, redeem before that to enjoy the gift!"
--
--     loyalty_rewards.claim_available_until ALREADY EXISTS and is already honoured end to end:
--     app.reward_availability_v432 reads it off the pinned loyalty_reward_versions row and
--     customer_get_reward_catalog already publishes it. Nothing about the engine changes here.
--     What was missing is a way to SET it from the screen the owner actually uses. The deep
--     versioned Loyalty editor (openRewardEditor) has had the field since v143; the Point system
--     page's own writers, business_create_reward_v326 / business_update_reward_v326, took no
--     expiry argument at all. Every one of the pilot firm's fourteen gifts therefore had
--     claim_available_until NULL, and the owner had no way to change that.
--
-- (2) "add another segment to add menu photos", written against the profile gallery. The owner
--     confirmed a SEPARATE menu gallery with its own segment in the customer app — not a tag on
--     the existing photos. A menu is a different promise from a room photo: one is what the
--     customer is choosing from, the other is what the place looks like.
--
-- WHY ONE MIGRATION FOR TWO UNRELATED THINGS: the governance cost of a migration in this repo is
-- eight files beyond the SQL, and these two ship in the same owner batch, against the same review,
-- on the same day. Splitting them doubles that cost and buys nothing — neither touches the other's
-- tables and the rollback suite exercises them independently.
--
-- WHAT IS DELIBERATELY NOT DONE:
--   * No storage-policy change. Menu photos are written under the SAME <business_id>/gallery/
--     prefix the v418 policy already allows, so no new storage kind is introduced and the v418
--     path CHECK below still governs both. See the note on the CHECK itself.
--   * claim_available_from is NOT exposed on the Point system page. The owner asked for an end
--     date; a start date is a scheduling feature with its own questions (what does the customer
--     see before it opens?) and inventing one here would be scope the owner did not ask for. The
--     column keeps working for the deep editor that already sets it.
--   * A gift whose end date has passed continues to leave the catalogue exactly as it does today
--     (app.reward_availability_v432 resolves it to 'ended' and the browser filters it out). The
--     owner was asked about this and answered about the BEFORE state instead — so the after
--     behaviour is left alone rather than changed on a guess.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. THE IMMUTABILITY GUARD MUST LEARN THE NEW COLUMN FIRST.
--
-- This is the landmine in this change and it is why this block comes before the writers.
-- app.reward_version_immutable_guard holds a hardcoded allowlist of the columns
-- business_update_reward_v326 is permitted to change on an ALREADY-PUBLISHED reward version while
-- holding the v423 token. Anything outside that list raises restrict_violation. Ship the writer
-- without widening the list and EVERY gift edit starts failing — not just edits that set a date,
-- because the writer sets the column on every call and `to_jsonb(new) - allowlist` would then
-- differ from `to_jsonb(old) - allowlist` on every row.
--
-- The list is restated in full rather than appended to, so the array in the database and the array
-- in this file are the same literal and a future reader can diff them at a glance.
-- ---------------------------------------------------------------------------------------------
create or replace function app.reward_version_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_config uuid; v_reward_version uuid; v_status text;
  -- v423: the columns public.business_update_reward_v326 owns. Anything outside this list stays
  -- immutable on a published row even with the token held.
  -- nestly_v472 adds claim_available_until: the Point system page can now set a gift's end date,
  -- and that write lands on the published version through the same v423 token path.
  v_owner_editable constant text[] := array[
    'internal_name','customer_name','description',
    'cost_points','credit_cents','estimated_cost_cents','image_ref',
    'claim_available_until'];
begin
  if tg_table_name = 'loyalty_reward_versions' then
    v_config := coalesce(new.config_version_id, old.config_version_id);
  else
    v_reward_version := coalesce(new.reward_version_id, old.reward_version_id);
    select config_version_id into v_config from public.loyalty_reward_versions where id = v_reward_version;
  end if;
  select status into v_status from public.firm_config_versions where id = v_config;
  if v_status is distinct from 'draft' then
    -- v423: the owner's edit of an already-published gift. NEW is only referenced under a proven
    -- tg_op = 'UPDATE', because NEW is unassigned in a DELETE trigger.
    if tg_op = 'UPDATE' and tg_table_name = 'loyalty_reward_versions' then
      if nullif(current_setting('app.v423_reward_edit_version_id', true), '') = old.id::text
         and (to_jsonb(new) - v_owner_editable) = (to_jsonb(old) - v_owner_editable) then
        return new;
      end if;
    end if;
    raise exception 'published reward configuration is immutable' using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $function$;

-- ---------------------------------------------------------------------------------------------
-- 2. THE TWO POINT-SYSTEM WRITERS GAIN THE END DATE.
--
-- CREATE OR REPLACE with a DEFAULTED new parameter rather than a new overload. An overload here
-- would be a PGRST203 outage waiting to happen: PostgREST cannot choose between two candidates
-- that differ only by an optional trailing argument, and this repo has already lost a day to
-- exactly that on the promotion finalize pair. One function, one signature, old callers unaffected.
--
-- p_claim_available_until is tri-state and the three states are all real:
--   NULL          -> leave whatever is stored alone (an old bundle calling without the argument
--                    must not silently wipe a date the deep editor set).
--   a timestamp   -> set it.
--   the sentinel  -> clear it. p_clear_end_date mirrors the p_clear_image flag this function
--                    already carries for exactly this reason, so the pattern is not a new one.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_create_reward_v326(
  p_business uuid, p_programme uuid, p_name text, p_points integer,
  p_credit_cents integer default 0, p_description text default null::text,
  p_image_ref text default null::text,
  p_claim_available_until timestamptz default null::timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
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
  -- nestly_v472: a gift that ends before it begins can never be claimed, and a firm that typed a
  -- date in the past has made a mistake the counter would silently absorb. Refused at the writer,
  -- not the browser, because the browser is not a place a rule can live.
  if p_claim_available_until is not null and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
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
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id,claim_available_until
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_description,p_image_ref,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target,p_claim_available_until
  );

  -- The versions row is what a customer is actually served (app.reward_availability_v432 reads
  -- rv.*), so the date has to land here too or it would be set and invisible.
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,image_ref,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id,claim_available_until
  ) values(
    v_reward_id,p_business,v_target,v_name,v_name,v_description,p_image_ref,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme,p_claim_available_until
  );

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
      'claim_available_until',p_claim_available_until,
      'version_split',v_split,'target_version_id',v_target,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
    'claim_available_until',p_claim_available_until,
    'version_split',v_split,'target_version_id',v_target)
    || v_commit;
end
$function$;

create or replace function public.business_update_reward_v326(
  p_business uuid, p_reward uuid, p_name text, p_points integer,
  p_description text default null::text, p_credit_cents integer default 0,
  p_image_ref text default null::text, p_clear_image boolean default false,
  p_claim_available_until timestamptz default null::timestamptz,
  p_clear_end_date boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_row public.loyalty_rewards%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_description text := nullif(btrim(coalesce(p_description,'')),'');
  v_image_ref text;
  v_end_date timestamptz;
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

  -- nestly_v472: same tri-state shape as the image above it — clear, set, or leave alone. Leaving
  -- alone is the branch an older bundle takes, and it must not wipe a date the deep editor set.
  v_end_date := case when p_clear_end_date then null
                     when p_claim_available_until is not null then p_claim_available_until
                     else v_row.claim_available_until end;
  -- Validated only when the owner is actually MOVING the date. A gift whose stored date has since
  -- passed must still be editable — renaming it, or fixing its points, cannot be blocked by a
  -- deadline that expired last month, and the owner clears or moves the date to revive it.
  if p_claim_available_until is not null and not p_clear_end_date
     and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
  end if;

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
         image_ref=v_image_ref, claim_available_until=v_end_date
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
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date
         where reward_id=p_reward and business_id=p_business
           and config_version_id=v_target;
      else
        perform set_config('app.v423_reward_edit_version_id', v_published.id::text, true);
        update public.loyalty_reward_versions
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date
         where id=v_published.id;
        perform set_config('app.v423_reward_edit_version_id', '', true);
      end if;
      v_published_synced := true;

      -- v423: bring stale draft clones along (a draft whose values already diverged is staged
      -- work and is not touched). The split draft is excluded by name — it already holds the
      -- new values. nestly_v472 adds claim_available_until to BOTH the set list and the
      -- "has this draft diverged?" comparison: a draft that already carries its own end date is
      -- staged work like any other divergence and must not be overwritten.
      with resynced as (
        update public.loyalty_reward_versions draft
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date
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
           and draft.claim_available_until is not distinct from v_published.claim_available_until
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
      'claim_available_until',v_end_date,
      'published_version_synced',v_published_synced,
      'active_config_version_id',v_active_version,
      'draft_versions_synced',v_drafts_synced,
      'version_split',v_split,'target_version_id',v_target,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',v_credit_cents,
    'claim_available_until',v_end_date,
    'published_version_synced',v_published_synced,
    'version_split',v_split,'target_version_id',v_target)
    || v_commit;
end
$function$;

-- Restated verbatim from the live proacl, per the repo's preflight rule. CREATE OR REPLACE
-- preserves grants, but the signature CHANGED (a new trailing parameter), so these are the grants
-- for the new identity and must be stated explicitly.
revoke all on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz) from public, anon;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz) to authenticated, service_role;
revoke all on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean) from public, anon;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean) to authenticated, service_role;

-- The pre-v472 overloads must go, or PostgREST sees two candidates for the same name and answers
-- PGRST203 to every caller — the promotion-finalize outage, repeated. Dropped AFTER the
-- replacements exist so there is no window in which neither is callable.
drop function if exists public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text);
drop function if exists public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean);

-- ---------------------------------------------------------------------------------------------
-- 3. THE MENU GALLERY.
--
-- One column on the table that already exists, not a second table. A menu photo is the same
-- object with the same owner, the same storage prefix, the same caption and the same ordering —
-- everything a second table would have duplicated. The `kind` is what differs, and it is what the
-- customer app splits on.
--
-- 'gallery' is the default so every existing row keeps its meaning without a backfill.
-- ---------------------------------------------------------------------------------------------
alter table public.business_gallery_v418
  add column if not exists kind text not null default 'gallery';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'business_gallery_v418_kind_check') then
    alter table public.business_gallery_v418
      add constraint business_gallery_v418_kind_check check (kind in ('gallery','menu'));
  end if;
end $$;

comment on column public.business_gallery_v418.kind is
  'nestly_v472. ''gallery'' = the room, the work, the shopfront. ''menu'' = what the customer is '
  'choosing from. Two separate segments in the customer app, two separate 12-photo allowances, '
  'one table because everything except the meaning is identical.';

-- The ordering index is per-kind now: the two segments sort independently and a menu photo must
-- not be interleaved with a room photo by a shared sort column.
drop index if exists business_gallery_v418_business_sort_idx;
create index if not exists business_gallery_v418_business_kind_sort_idx
  on public.business_gallery_v418(business_id, kind, sort, created_at);

-- The writer takes a kind and replaces ONLY that kind's rows. This is the whole reason it is a
-- parameter rather than a field on each item: the function's contract is "these are now all of
-- this business's <kind> photos", and a delete scoped to the wrong set would wipe the segment the
-- owner was not editing. Saving the gallery must never be able to delete the menu.
create or replace function public.business_set_gallery_v418(
  p_business uuid, p_items jsonb default '[]'::jsonb, p_kind text default 'gallery')
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_count integer;
  v_kind text := coalesce(nullif(btrim(coalesce(p_kind,'')),''),'gallery');
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner access required to edit the business profile' using errcode='42501';
  end if;
  if v_kind not in ('gallery','menu') then
    raise exception 'unknown photo segment' using errcode='22023';
  end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' then
    raise exception 'gallery must be a list of photos' using errcode='22023';
  end if;
  select count(*) into v_count from jsonb_array_elements(coalesce(p_items,'[]'::jsonb));
  if v_count > 12 then
    raise exception 'a profile gallery holds up to 12 photos' using errcode='23514';
  end if;

  /* Every image must be one THIS business owns, in the gallery folder. The check is here and not
     only in the browser because the browser is not a place a rule can live: without it an owner
     could point a row at another firm's storage object and the customer app would render it.
     nestly_v472: menu photos share the same <business_id>/gallery/ prefix deliberately — the
     storage policy already allows it, the ownership proof is identical, and minting a second
     storage kind would have meant a second policy to keep in step with this one for no gain. */
  if exists(
    select 1 from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) item
     where coalesce(item->>'image_ref','') !~ (
       '/storage/v1/object/public/business-public/'||p_business::text||'/gallery/'||
       '[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$')
  ) then
    raise exception 'a gallery photo must be an image uploaded to this business' using errcode='22023';
  end if;

  delete from public.business_gallery_v418 where business_id = p_business and kind = v_kind;
  insert into public.business_gallery_v418(business_id, image_ref, caption, sort, created_by, kind)
  select p_business,
         item->>'image_ref',
         nullif(btrim(coalesce(item->>'caption','')),''),
         (ordinality - 1)::integer,
         auth.uid(),
         v_kind
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality as t(item, ordinality);

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'business_profile.gallery_set', 'businesses', p_business,
    jsonb_build_object('photos', v_count, 'kind', v_kind));

  return jsonb_build_object('status','ok','photos', v_count, 'kind', v_kind);
end $function$;

revoke all on function public.business_set_gallery_v418(uuid,jsonb,text) from public, anon;
grant execute on function public.business_set_gallery_v418(uuid,jsonb,text) to authenticated, service_role;
drop function if exists public.business_set_gallery_v418(uuid,jsonb);

-- ---------------------------------------------------------------------------------------------
-- 4. THE CUSTOMER READ CARRIES THE MENU.
--
-- Patched in place with a targeted replace rather than restated, because
-- customer_get_business_summary is a large function this change touches two lines of, and
-- restating it here would make this migration the authority on 300 lines it has no opinion about.
-- The replace is asserted to have happened; a source that no longer matches aborts the migration
-- rather than silently shipping a summary with no menu in it.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_src text;
  v_old constant text := $marker$      'gallery', coalesce((select jsonb_agg(jsonb_build_object('image_ref', g.image_ref,
                                                              'caption', g.caption)
                             order by g.sort, g.created_at)
                             from public.business_gallery_v418 g
                            where g.business_id = v_context.business_id),'[]'::jsonb),$marker$;
  v_new constant text := $marker$      -- nestly_v472: scoped to kind='gallery' so the menu below is not folded into it.
      'gallery', coalesce((select jsonb_agg(jsonb_build_object('image_ref', g.image_ref,
                                                              'caption', g.caption)
                             order by g.sort, g.created_at)
                             from public.business_gallery_v418 g
                            where g.business_id = v_context.business_id
                              and g.kind = 'gallery'),'[]'::jsonb),
      -- nestly_v472 (owner: "add another segment to add menu photos", confirmed as its own
      -- segment in the customer app). Same shape as the gallery beside it, same read, no new
      -- customer endpoint.
      'menu', coalesce((select jsonb_agg(jsonb_build_object('image_ref', g.image_ref,
                                                            'caption', g.caption)
                             order by g.sort, g.created_at)
                             from public.business_gallery_v418 g
                            where g.business_id = v_context.business_id
                              and g.kind = 'menu'),'[]'::jsonb),$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_summary';
  if v_src is null then
    raise exception 'customer_get_business_summary is missing' using errcode='42883';
  end if;
  if position(v_old in v_src) = 0 then
    raise exception 'customer_get_business_summary no longer contains the v418 gallery block this migration patches'
      using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $$;

commit;
