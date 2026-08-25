-- nestly_v505 — the first gift can be saved before the programme has ever gone live.
--
-- THE DEFECT (P0, live). public.business_create_reward_v326 refused every call from a business
-- whose businesses.active_config_version_id is null:
--
--     if v_active_version is null then
--       raise exception 'this business has no published loyalty configuration yet' using errcode='XX001';
--
-- A brand-new tenant HAS no published configuration. app.seed_loyalty_config_version() writes the
-- v1 firm_config_versions row with the loyalty_programs row's own configuration_status, and both
-- onboarding and the super-admin activation backfill seed that as 'draft' — so v1 is a draft,
-- active_config_version_id stays null, and only publish_loyalty_config ever fills it in.
--
-- The Rewards Programme surface is an immediate-write surface: "Continue set up" on the Point
-- system card opens the live gift editor, whose Save calls this writer directly. So the owner of
-- every never-published tenant met a chicken-and-egg: the gift editor demands a published config,
-- and going live demands a gift. Eight production businesses were sitting on zero gifts because
-- of it, AhXiang among them — its owner hit this refusal 20+ times in one hour on 2026-08-25.
--
-- THE FIX. A business with no published configuration is not broken, it is unfinished: it already
-- owns a draft version, and a draft is exactly where unpublished work belongs. Both reward writers
-- now resolve their target as "the published version if there is one, otherwise this business's
-- own draft", and say so in the reply.
--
-- Nothing about what customers see changes. With active_config_version_id null,
-- app.reward_availability_v432 reads no version at all, so a gift written into the draft is
-- invisible to customers until publish_loyalty_config carries the whole configuration live — which
-- is what "On · unpublished" on the tile has been telling the owner all along. The reply carries
-- publish_status='pending' with a blocker, which the browser's existing
-- growStampPublishToastV433 helper (v433) already renders as "Saved — <message>" instead of the
-- false "Gift added and live for customers".
--
-- business_update_reward_v326 gets the same target resolution. It never RAISED on a null active
-- version — it updated public.loyalty_rewards and silently skipped the version write — which was
-- fine only while no draft-only reward version could exist. Now that create can make one, an edit
-- that skipped it would leave the draft holding the pre-edit text, and publishing would push those
-- stale values live. It writes the draft row too.

begin;

-- ---------------------------------------------------------------------------------------------
-- The shared resolution. loyalty_programs.current_config_version_id is the row the seed trigger
-- and every draft-save keep pointed at the configuration in hand, so it is preferred; the newest
-- draft is the fallback for a business whose pointer was never moved. Both are constrained to
-- status='draft' — a published or superseded version must never be reached this way, and the
-- immutability guard on loyalty_reward_versions would refuse it anyway.
create or replace function app.reward_draft_target_v505(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select coalesce(
    (select lp.current_config_version_id
       from public.loyalty_programs lp
       join public.firm_config_versions fcv
         on fcv.id = lp.current_config_version_id
        and fcv.business_id = p_business
        and fcv.status = 'draft'
      where lp.business_id = p_business),
    (select fcv.id
       from public.firm_config_versions fcv
      where fcv.business_id = p_business
        and fcv.status = 'draft'
      order by fcv.version_no desc, fcv.created_at desc
      limit 1))
$function$;

comment on function app.reward_draft_target_v505(uuid) is
  'nestly_v505: the config version a reward write lands in when the business has never published — its own newest draft, never a published or superseded version.';

-- The one sentence an owner reads when a gift is saved before go-live. Kept here so the create and
-- update writers cannot drift apart, and worded to finish the browser's "Saved — " prefix.
create or replace function app.reward_unpublished_commit_v505()
returns jsonb
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select jsonb_build_object(
    'publish_status', 'pending',
    'blockers', jsonb_build_array(jsonb_build_object(
      'code', 'loyalty_not_published',
      'message', 'your rewards programme has not gone live yet, so customers cannot see this gift until you finish setting it up')))
$function$;

comment on function app.reward_unpublished_commit_v505() is
  'nestly_v505: the pending-publish reply a reward writer returns when the business has no published loyalty configuration.';

-- ---------------------------------------------------------------------------------------------
create or replace function public.business_create_reward_v326(
  p_business uuid, p_programme uuid, p_name text, p_points integer,
  p_credit_cents integer default 0, p_description text default null,
  p_image_ref text default null,
  p_claim_available_until timestamptz default null,
  p_where_it_works text default null)
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
  v_unpublished boolean := false;   -- nestly_v505
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
  -- nestly_v472: a gift that ends in the past can never be claimed. Refused at the writer, not
  -- the browser, because the browser is not a place a rule can live.
  if p_claim_available_until is not null and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=p_programme and spine.business_id=p_business) then
    raise exception 'programme does not belong to this business' using errcode='42501';
  end if;
  select active_config_version_id into v_active_version
    from public.businesses where id=p_business;

  v_is_stamp := exists (
    select 1 from public.business_programmes spine
     where spine.id = p_programme and spine.business_id = p_business
       and spine.kind = 'stamps' and spine.active);

  if v_active_version is null then
    -- nestly_v505: never published. Land in the business's own draft rather than refusing the
    -- owner's first gift. No stamp version split here — app.stamp_config_edit_begin_v433 exists to
    -- protect cards pinned to a PUBLISHED version, and there is none.
    v_target := app.reward_draft_target_v505(p_business);
    if v_target is null then
      raise exception 'this business has no loyalty configuration to hold a gift yet' using errcode='XX001';
    end if;
    v_unpublished := true;
    v_commit := app.reward_unpublished_commit_v505();
  elsif v_is_stamp then
    v_target := app.stamp_config_edit_begin_v433(p_business);
    v_split := (v_target is distinct from v_active_version);
  else
    v_target := v_active_version;
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_rewards where business_id=p_business;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,description,image_ref,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id,claim_available_until,where_it_works
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_description,p_image_ref,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target,p_claim_available_until,nullif(btrim(coalesce(p_where_it_works,'')),'')
  );

  -- The versions row is what a customer is actually served (app.reward_availability_v432 reads
  -- rv.*), so the date has to land here too or it would be set and invisible.
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,image_ref,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id,claim_available_until,where_it_works
  ) values(
    v_reward_id,p_business,v_target,v_name,v_name,v_description,p_image_ref,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme,p_claim_available_until,nullif(btrim(coalesce(p_where_it_works,'')),'')
  );

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
      'claim_available_until',p_claim_available_until,
      'version_split',v_split,'target_version_id',v_target,
      'unpublished_draft',v_unpublished,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
    'claim_available_until',p_claim_available_until,
    'version_split',v_split,'target_version_id',v_target,
    'unpublished_draft',v_unpublished)
    || v_commit;
end
$function$;

revoke all on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text) from public, anon;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
create or replace function public.business_update_reward_v326(
  p_business uuid, p_reward uuid, p_name text, p_points integer,
  p_description text default null, p_credit_cents integer default 0,
  p_image_ref text default null, p_clear_image boolean default false,
  p_claim_available_until timestamptz default null,
  p_clear_end_date boolean default false,
  p_where_it_works text default null)
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
  v_end_date timestamptz;
  v_where text;
  v_credit_cents integer := coalesce(p_credit_cents,0);
  v_active_version uuid;
  v_is_stamp boolean := false;
  v_target uuid;
  v_split boolean := false;
  v_unpublished boolean := false;   -- nestly_v505
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
  -- passed must still be renameable.
  if p_claim_available_until is not null and not p_clear_end_date
     and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
  end if;

  v_where := case when p_where_it_works is null then v_row.where_it_works
                  else nullif(btrim(p_where_it_works),'') end;

  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  -- nestly_v433: is this a stamp-card gift on the running stamp programme? Those edits must not
  -- touch the version open cards are pinned to.
  v_is_stamp := exists (
    select 1 from public.business_programmes spine
     where spine.id = v_row.programme_id and spine.business_id = p_business
       and spine.kind = 'stamps' and spine.active);

  if v_active_version is null then
    -- nestly_v505: the mirror of the create path. Before this the version write was skipped
    -- entirely, so a draft-only gift kept its pre-edit wording and price and publishing would have
    -- made the STALE row live.
    v_target := app.reward_draft_target_v505(p_business);
    v_unpublished := true;
    v_commit := app.reward_unpublished_commit_v505();
  elsif v_is_stamp then
    v_target := app.stamp_config_edit_begin_v433(p_business);
    v_split := (v_target is distinct from v_active_version);
  else
    v_target := v_active_version;
  end if;

  update public.loyalty_rewards
     set name=v_name, internal_name=v_name, customer_name=v_name,
         description=v_description, cost_points=p_points,
         credit_cents=v_credit_cents, estimated_cost_cents=v_credit_cents,
         image_ref=v_image_ref, claim_available_until=v_end_date, where_it_works=v_where
   where id=p_reward and business_id=p_business;

  if v_unpublished then
    -- One draft, one row, no published sibling to diverge from: a plain update, guarded only by
    -- the target actually being a draft of THIS business (app.reward_draft_target_v505's contract).
    if v_target is not null then
      update public.loyalty_reward_versions
         set internal_name=v_name, customer_name=v_name, description=v_description,
             cost_points=p_points, credit_cents=v_credit_cents,
             estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
             claim_available_until=v_end_date, where_it_works=v_where
       where reward_id=p_reward and business_id=p_business
         and config_version_id=v_target;
      if found then v_drafts_synced := 1; end if;
    end if;
  elsif v_active_version is not null then
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
               claim_available_until=v_end_date, where_it_works=v_where
         where reward_id=p_reward and business_id=p_business
           and config_version_id=v_target;
      else
        perform set_config('app.v423_reward_edit_version_id', v_published.id::text, true);
        update public.loyalty_reward_versions
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date, where_it_works=v_where
         where id=v_published.id;
        perform set_config('app.v423_reward_edit_version_id', '', true);
      end if;
      v_published_synced := true;

      -- v423: bring stale draft clones along. nestly_v472 adds claim_available_until to BOTH the
      -- set list and the "has this draft diverged?" comparison — a draft already carrying its own
      -- end date is staged work and must not be overwritten.
      with resynced as (
        update public.loyalty_reward_versions draft
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date, where_it_works=v_where
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
           and draft.where_it_works is not distinct from v_published.where_it_works
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
      'unpublished_draft',v_unpublished,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',v_credit_cents,
    'claim_available_until',v_end_date,
    'published_version_synced',v_published_synced,
    'version_split',v_split,'target_version_id',v_target,
    'unpublished_draft',v_unpublished)
    || v_commit;
end
$function$;

revoke all on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text) from public, anon;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text) to authenticated, service_role;

revoke all on function app.reward_draft_target_v505(uuid) from public, anon;
revoke all on function app.reward_unpublished_commit_v505() from public, anon;

commit;
