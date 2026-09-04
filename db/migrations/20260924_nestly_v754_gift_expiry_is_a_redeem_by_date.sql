-- nestly_v754 — a points gift's "Expires after" is the date it stops being redeemable, not a
-- post-claim countdown.
--
-- OWNER RULING (2026-09-04, batch 2 photo 1, verbatim): "the expiry should be example 90 days —
-- means after 90 days the reward would not be available to redeem with points (will not be
-- shown in the customer app for redemption) and customer will see exactly when the reward will
-- expire & after expiry, customer will use their points to redeem other rewards."
--
-- WHY THE OLD READING WAS WRONG. nestly_v520 gave the points-gift quick editor a days field and
-- wired it to loyalty_rewards.entitlement_expiry_days — "days a customer has to use this gift
-- once they take it", a POST-REDEMPTION countdown copied from the stamp card's earned-reward
-- shelf life (v464). But a points gift has no earn instant to start that clock from (v520's own
-- reasoning), and now that every earning rule shows its own points expiry inline (v748: "When
-- points expire: a fixed number of days"), a second, differently-scoped expiry on the gift itself
-- reads as the same thing and is not. The owner's words above describe a single concept: a
-- redeem-by deadline for the GIFT in the catalogue.
--
-- ONE CLOCK, NOT A THIRD. loyalty_rewards/loyalty_reward_versions.claim_available_until already
-- IS that deadline — nestly_v472 added it as "the OFFERING window (this gift leaves the catalogue
-- on that date)", and it is already the one thing every reader and every redemption path
-- enforces: app.reward_availability_v432 (customer catalogue, customer actions, staff redeem-now
-- list — v432/v566) reports 'ended' once it has passed; app.redeem_reward_core refuses with
-- 'reward expired'; customer_create_redemption_intent_v89 refuses with 'reward is unavailable'.
-- None of that enforcement is new — it has been live since v472/v89. What was missing was a way
-- for the owner to SET it as "N days from now" instead of picking an absolute date, because the
-- quick points-gift dialog (growPointsAddFormV326) only ever exposed a days field, and that days
-- field was wired to the wrong column.
--
-- THIS MIGRATION does exactly one thing: it teaches business_create_reward_v326 and
-- business_update_reward_v326 a new optional parameter, p_claim_expires_after_days. When given,
-- the writer computes claim_available_until itself, at THIS CALL'S now() — the publish instant —
-- and pins that computed value into both the live loyalty_rewards row and the
-- loyalty_reward_versions row the save just published or drafted, the same single write path
-- both writers already use for every other field (so the value is immutable on a published
-- version exactly like every other owner-editable column — app.reward_version_immutable_guard
-- already allowlists claim_available_until, unchanged here). It does not touch
-- entitlement_expiry_days, does not drop or rename any column, table, or function, and does not
-- touch redeem_reward_core, customer_create_redemption_intent_v89, or app.reward_availability_v432
-- — their existing claim_available_until enforcement is exactly the behaviour this migration
-- reuses, not something it needs to add.
--
-- The app.js side (same commit, not this file) stops sending p_entitlement_expiry_days from the
-- points quick-add dialog's "Expires after" field and sends p_claim_expires_after_days instead;
-- relabels the field's helper text; and shows the derived "Expires on <date>" both live in the
-- dialog (from the RPC's own response) and in the read-only gift detail list.

begin;

create or replace function public.business_create_reward_v326(
  p_business uuid,
  p_programme uuid,
  p_name text,
  p_points integer,
  p_credit_cents integer default 0,
  p_description text default null::text,
  p_image_ref text default null::text,
  p_claim_available_until timestamp with time zone default null::timestamp with time zone,
  p_where_it_works text default null::text,
  p_entitlement_expiry_days integer default null::integer,
  p_claim_expires_after_days integer default null::integer
)
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
  v_unpublished boolean := false;
  v_sort integer;
  v_expiry_days integer;
  v_claim_until timestamptz;
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
  -- nestly_v754: an end date and a "days from now" both name the same column. Accepting both at
  -- once would make one of them a silent no-op, so it is refused instead.
  if p_claim_available_until is not null and p_claim_expires_after_days is not null then
    raise exception 'send a gift end date or an expiry day count, not both' using errcode='22023';
  end if;
  if p_claim_expires_after_days is not null and p_claim_expires_after_days <= 0 then
    raise exception 'gift expiry must be at least 1 day' using errcode='22023';
  end if;
  if p_claim_available_until is not null and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
  end if;
  if p_entitlement_expiry_days is not null and p_entitlement_expiry_days <= 0 then
    raise exception 'gift expiry must be at least 1 day' using errcode='22023';
  end if;
  -- nestly_v754: the PUBLISH INSTANT is this call's own now() — computed once, here, so the
  -- pinned value never moves even if the surrounding transaction runs long.
  v_claim_until := case when p_claim_expires_after_days is not null
    then now() + make_interval(days => p_claim_expires_after_days)
    else p_claim_available_until end;
  v_expiry_days := p_entitlement_expiry_days;
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
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id,claim_available_until,where_it_works,entitlement_expiry_days
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_description,p_image_ref,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target,v_claim_until,nullif(btrim(coalesce(p_where_it_works,'')),''),v_expiry_days
  );

  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,description,image_ref,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id,claim_available_until,where_it_works,entitlement_expiry_days
  ) values(
    v_reward_id,p_business,v_target,v_name,v_name,v_description,p_image_ref,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme,v_claim_until,nullif(btrim(coalesce(p_where_it_works,'')),''),v_expiry_days
  );

  if v_split then
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
      'claim_available_until',v_claim_until,
      'claim_expires_after_days',p_claim_expires_after_days,
      'entitlement_expiry_days',v_expiry_days,
      'version_split',v_split,'target_version_id',v_target,
      'unpublished_draft',v_unpublished,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0),
    'claim_available_until',v_claim_until,
    'entitlement_expiry_days',v_expiry_days,
    'version_split',v_split,'target_version_id',v_target,
    'unpublished_draft',v_unpublished)
    || v_commit;
end
$function$;

create or replace function public.business_update_reward_v326(
  p_business uuid,
  p_reward uuid,
  p_name text,
  p_points integer,
  p_description text default null::text,
  p_credit_cents integer default 0,
  p_image_ref text default null::text,
  p_clear_image boolean default false,
  p_claim_available_until timestamp with time zone default null::timestamp with time zone,
  p_clear_end_date boolean default false,
  p_where_it_works text default null::text,
  p_entitlement_expiry_days integer default null::integer,
  p_clear_expiry_days boolean default false,
  p_claim_expires_after_days integer default null::integer
)
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
  v_expiry_days integer;
  v_credit_cents integer := coalesce(p_credit_cents,0);
  v_active_version uuid;
  v_is_stamp boolean := false;
  v_target uuid;
  v_split boolean := false;
  v_unpublished boolean := false;
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

  -- nestly_v754: an end date and a "days from now" both name the same column — refused together,
  -- same rule as the create writer.
  if p_claim_available_until is not null and p_claim_expires_after_days is not null then
    raise exception 'send a gift end date or an expiry day count, not both' using errcode='22023';
  end if;
  if p_claim_expires_after_days is not null and p_claim_expires_after_days <= 0 then
    raise exception 'gift expiry must be at least 1 day' using errcode='22023';
  end if;

  -- nestly_v754: "days from now" is computed at THIS call's now() — the publish instant — and
  -- wins over both the absolute-date parameter and p_clear_end_date when supplied, because it is
  -- the one signal that means the owner touched THIS field on THIS save. When it is null, the
  -- older explicit-date / explicit-clear contract (nestly_v472/p2-F082) is unchanged.
  v_end_date := case
    when p_claim_expires_after_days is not null then now() + make_interval(days => p_claim_expires_after_days)
    when p_clear_end_date then null
    when p_claim_available_until is not null then p_claim_available_until
    else v_row.claim_available_until end;
  if p_claim_expires_after_days is null and p_claim_available_until is not null and not p_clear_end_date
     and p_claim_available_until <= now() then
    raise exception 'a gift end date must be in the future' using errcode='22023';
  end if;

  v_where := case when p_where_it_works is null then v_row.where_it_works
                  else nullif(btrim(p_where_it_works),'') end;

  -- nestly_v519: null means "leave what is stored alone" — an older app bundle that does not know
  -- this parameter must not silently wipe an expiry the owner set. Clearing is therefore an
  -- explicit act, the same shape p_clear_end_date has. Zero and negative are refused rather than
  -- coerced: "expires after 0 days" is not a thing an owner means, and silently storing it would
  -- make every gift unusable the instant it is taken.
  if p_entitlement_expiry_days is not null and p_entitlement_expiry_days <= 0 then
    raise exception 'gift expiry must be at least 1 day' using errcode='22023';
  end if;
  v_expiry_days := case when p_clear_expiry_days then null
                        when p_entitlement_expiry_days is not null then p_entitlement_expiry_days
                        else v_row.entitlement_expiry_days end;

  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  v_is_stamp := exists (
    select 1 from public.business_programmes spine
     where spine.id = v_row.programme_id and spine.business_id = p_business
       and spine.kind = 'stamps' and spine.active);

  if v_active_version is null then
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
         image_ref=v_image_ref, claim_available_until=v_end_date, where_it_works=v_where, entitlement_expiry_days=v_expiry_days
   where id=p_reward and business_id=p_business;

  if v_unpublished then
    if v_target is not null then
      update public.loyalty_reward_versions
         set internal_name=v_name, customer_name=v_name, description=v_description,
             cost_points=p_points, credit_cents=v_credit_cents,
             estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
             claim_available_until=v_end_date, where_it_works=v_where, entitlement_expiry_days=v_expiry_days
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
               claim_available_until=v_end_date, where_it_works=v_where, entitlement_expiry_days=v_expiry_days
         where reward_id=p_reward and business_id=p_business
           and config_version_id=v_target;
      else
        perform set_config('app.v423_reward_edit_version_id', v_published.id::text, true);
        update public.loyalty_reward_versions
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date, where_it_works=v_where, entitlement_expiry_days=v_expiry_days
         where id=v_published.id;
        perform set_config('app.v423_reward_edit_version_id', '', true);
      end if;
      v_published_synced := true;

      with resynced as (
        update public.loyalty_reward_versions draft
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref,
               claim_available_until=v_end_date, where_it_works=v_where, entitlement_expiry_days=v_expiry_days
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
           and draft.entitlement_expiry_days is not distinct from v_published.entitlement_expiry_days
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
      'claim_expires_after_days',p_claim_expires_after_days,
      'entitlement_expiry_days',v_expiry_days,
      'published_version_synced',v_published_synced,
      'active_config_version_id',v_active_version,
      'draft_versions_synced',v_drafts_synced,
      'version_split',v_split,'target_version_id',v_target,
      'unpublished_draft',v_unpublished,
      'publish_status',v_commit->>'publish_status'));

  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',v_credit_cents,
    'claim_available_until',v_end_date,
    'entitlement_expiry_days',v_expiry_days,
    'published_version_synced',v_published_synced,
    'version_split',v_split,'target_version_id',v_target,
    'unpublished_draft',v_unpublished)
    || v_commit;
end
$function$;

-- Same ACL as the pre-v754 overloads (postgres/authenticated/service_role, no PUBLIC execute) —
-- CREATE OR REPLACE keeps the function's OID and grants, but the exact overload signature just
-- changed (a new trailing parameter), so PostgreSQL's own default PUBLIC execute grant on a
-- freshly-defined function is revoked explicitly here rather than assumed away.
revoke all on function public.business_create_reward_v326(
  uuid, uuid, text, integer, integer, text, text, timestamp with time zone, text, integer, integer
) from public;
grant execute on function public.business_create_reward_v326(
  uuid, uuid, text, integer, integer, text, text, timestamp with time zone, text, integer, integer
) to postgres, authenticated, service_role;

revoke all on function public.business_update_reward_v326(
  uuid, uuid, text, integer, text, integer, text, boolean, timestamp with time zone, boolean, text, integer, boolean, integer
) from public;
grant execute on function public.business_update_reward_v326(
  uuid, uuid, text, integer, text, integer, text, boolean, timestamp with time zone, boolean, text, integer, boolean, integer
) to postgres, authenticated, service_role;

commit;
