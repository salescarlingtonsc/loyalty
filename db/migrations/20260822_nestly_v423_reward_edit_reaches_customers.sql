-- nestly_v423 — an edit to a live gift reaches the customer who is offered it.
--
-- P0, confirmed against production 2026-08-22. An owner who renames, reprices, re-describes or
-- re-photographs an ALREADY-PUBLISHED gift on the simplified Points System page sees the change
-- take effect on their own screen and nowhere else. The customer's catalogue keeps showing the
-- old name at the old price, and a redemption is quoted and charged at the old price. The owner
-- has no way to tell: their page reads back the row they just wrote.
--
-- WHY — v343 SHIPPED ON A CLAIM ABOUT THE READER THAT IS NOT TRUE
-- v343's own header says, in the section headed "WHY THIS DOES NOT TOUCH loyalty_reward_versions":
--   "Only public.loyalty_rewards is the current-state source of truth this page
--    (and customer_get_reward_catalog) reads."
-- The parenthesis is wrong, and it is the whole defect. public.customer_get_reward_catalog does
-- not read public.loyalty_rewards for any displayed field. It reads:
--     from public.businesses b
--     join public.loyalty_reward_versions rv
--       on rv.business_id = b.id and rv.config_version_id = b.active_config_version_id and rv.active
-- and takes customer_name, description, image_ref, terms, instructions, taxonomy_label,
-- fulfillment_kind, cost_points, claim_available_from/until, entitlement_expiry_days, usage_limit
-- and the tier gate off `rv`. It touches public.loyalty_rewards for exactly one thing — the V371
-- `not exists (... live_reward.paused ...)` suppression — which is precisely why pause and delete
-- DO reach the customer and an edit does not. app.redeem_reward_core prices the same way: every
-- figure it charges (v_version.cost_points, v_version.credit_cents) comes off the version row.
--
-- v343's verification note recorded the bug as if it were the specification — check 1 reads
-- "loyalty_reward_versions row count for that reward the SAME before and after the edit". The row
-- count was indeed unchanged. So was the customer's price.
--
-- WHAT THIS CHANGES
-- The owner edit now restates the SAME seven fields it already writes to the live row onto the
-- published snapshot the customer is actually served — the reward's row under the business's
-- current active_config_version_id. Nothing else about the RPC moves.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * It does not publish anything. If the business has no active_config_version_id, or the gift
--     has no row under it (created but never published), the RPC keeps v343's behaviour exactly —
--     the live row is updated and no version row is invented. Inventing a publish here would put
--     a half-configured gift in front of customers.
--   * It does not move a stamp customer mid-card. app.redeem_reward_core resolves a stamp gift
--     against app.stamp_cycle_version_v416 — the version the customer's OPEN card was started
--     under — not the active one. That is the v416 owner ruling ("only from their next card") and
--     it still holds: this edit lands on the active version, so a part-filled card keeps the deal
--     it started on and the next card gets the new one. Points gifts have no cycle and change
--     immediately, which is what the owner is asking for.
--   * It does not touch fulfillment_kind. business_create_reward_v326 derives it from
--     credit_cents at creation; v343's update never restated it on the live row either, and
--     changing what a redemption *is* (credit vs manual item) is not what "edit this gift" means.
--
-- WHY THE IMMUTABILITY GUARD HAD TO LEARN ONE EXCEPTION
-- public.loyalty_reward_versions is protected by trg_loyalty_reward_versions_immutable
-- (app.reward_version_immutable_guard) — any UPDATE or DELETE of a row whose config version is
-- not a draft is refused with restrict_violation. A plain UPDATE from the RPC would therefore
-- have failed at run time, turning a silent no-op into a loud one. Note the guard covers UPDATE
-- and DELETE only: business_create_reward_v326 has always INSERTed straight into the active
-- PUBLISHED version, so "the v326 immediate-write family edits the live published snapshot" is
-- an existing, deliberate property of this module, not something introduced here. v423 makes
-- update consistent with create instead of leaving one of the two silently inert.
--
-- The exception is deliberately narrow. A published row may be updated only when ALL of:
--   (a) it is an UPDATE on loyalty_reward_versions (never a DELETE, never the eligibility
--       child tables, which the same guard function also serves);
--   (b) the transaction-local token app.v423_reward_edit_version_id names that exact row —
--       set immediately before the statement and cleared immediately after, the same pattern
--       app.redeem_reward_core already uses for app.points_ledger_insert_id and
--       app.credit_ledger_write_scope; and
--   (c) every column OUTSIDE the seven the owner edit owns is byte-identical between OLD and
--       NEW. Identity, tenancy, config_version_id, programme_id, active, sort, created_at and
--       the whole scheduling/gating set the draft-and-publish editor owns remain immutable, so
--       the hatch cannot be used to re-point a version row at another reward or another tenant.
-- The token is not a privilege boundary and is not relied on as one: `authenticated` holds SELECT
-- and nothing else on this table (verified in prod), anon holds nothing at all, and RLS is on —
-- the only writer is a SECURITY DEFINER function owned by postgres. The token exists so that one
-- named statement inside one named function is the only edit that can happen, and so that an
-- accidental future UPDATE elsewhere still fails the way it does today.
--
-- STALE DRAFTS CANNOT UNDO THE EDIT
-- publish_loyalty_config copies a draft's reward rows back onto public.loyalty_rewards and makes
-- that draft the active version. A draft cloned before this edit therefore holds the pre-edit
-- name and price, and publishing it later would silently revert the owner's change on both the
-- live row and the customer's catalogue. business_delete_reward_v326 already defends against
-- exactly this for deletes ("so that publishing an unrelated draft later cannot resurrect this
-- delete"). The same defence is applied here, with one restriction delete does not need: a draft
-- row is only re-synced when it still matches the values the published row held BEFORE this edit.
-- A draft the owner has deliberately staged different values into is left completely alone. This
-- also fixes delete's `limit 1` blind spot in passing — the sync is set-based over every open
-- draft, and production currently has one business carrying eleven of them.
--
-- HYGIENE, in section 3 — unrelated to the defect above, batched here because it is the same
-- module's grant posture and the v423 review surfaced it.
--
-- APPLY ORDER: after 20260822_nestly_v422_customer_reward_history.sql. No data migration, no
-- backfill: existing published version rows are left exactly as they are, and the next edit of
-- any given gift brings its snapshot into line.

begin;

-- ============================================================================================
-- 1. THE IMMUTABILITY GUARD LEARNS ONE NAMED EXCEPTION
-- ============================================================================================
-- Unchanged from production except for the v423 block. This function backs four triggers —
-- trg_loyalty_reward_versions_immutable plus the branches/services/products eligibility tables —
-- and the exception is scoped so the other three behave exactly as before.
create or replace function app.reward_version_immutable_guard()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_config uuid; v_reward_version uuid; v_status text;
  -- v423: the seven columns public.business_update_reward_v326 owns. Anything outside this list
  -- stays immutable on a published row even with the token held.
  v_owner_editable constant text[] := array[
    'internal_name','customer_name','description',
    'cost_points','credit_cents','estimated_cost_cents','image_ref'];
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

comment on function app.reward_version_immutable_guard() is
  'A published loyalty configuration is immutable. v423 carves out exactly one exception: '
  'public.business_update_reward_v326 restating its own seven columns on one named '
  'loyalty_reward_versions row, proven by the transaction-local token '
  'app.v423_reward_edit_version_id and by every other column being unchanged.';

-- ============================================================================================
-- 2. THE OWNER EDIT REACHES THE PUBLISHED SNAPSHOT THE CUSTOMER IS SERVED
-- ============================================================================================
-- Re-issued from the production body. Production carries exactly ONE signature of this function
-- (uuid,uuid,text,integer,text,integer,text,boolean) — confirmed from pg_proc, so there is no
-- second overload to keep in step. Everything down to and including the live-row UPDATE is v343
-- verbatim apart from hoisting the three-state image decision into v_image_ref so the live row
-- and the snapshot cannot disagree about it.
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
  v_published public.loyalty_reward_versions%rowtype;
  v_published_synced boolean := false;
  v_drafts_synced integer := 0;
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

  -- The same three-state photo contract v343 defined: p_clear_image removes it, a supplied
  -- p_image_ref replaces it, an unset param leaves it alone. Resolved once, written twice.
  v_image_ref := case when p_clear_image then null
                      when p_image_ref is not null then p_image_ref
                      else v_row.image_ref end;

  update public.loyalty_rewards
     set name=v_name, internal_name=v_name, customer_name=v_name,
         description=v_description, cost_points=p_points,
         credit_cents=v_credit_cents, estimated_cost_cents=v_credit_cents,
         image_ref=v_image_ref
   where id=p_reward and business_id=p_business;

  -- V423: and now the row the customer is actually served. customer_get_reward_catalog and
  -- app.redeem_reward_core both read public.loyalty_reward_versions at the business's
  -- active_config_version_id; without this the edit above is invisible to both.
  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  if v_active_version is not null then
    select * into v_published from public.loyalty_reward_versions
     where reward_id=p_reward and business_id=p_business
       and config_version_id=v_active_version
     for update;

    -- No row under the active version means this gift has never been published. Leave it
    -- live-only, exactly as before — an owner edit is not a publish.
    if found then
      perform set_config('app.v423_reward_edit_version_id', v_published.id::text, true);
      update public.loyalty_reward_versions
         set internal_name=v_name, customer_name=v_name, description=v_description,
             cost_points=p_points, credit_cents=v_credit_cents,
             estimated_cost_cents=v_credit_cents, image_ref=v_image_ref
       where id=v_published.id;
      perform set_config('app.v423_reward_edit_version_id', '', true);
      v_published_synced := true;

      -- A draft cloned from the pre-edit published row would silently revert this change the
      -- next time it is published (publish_loyalty_config writes a draft's reward rows back onto
      -- public.loyalty_rewards). Bring those stale clones along. A draft whose values have
      -- ALREADY diverged is staged work and is not touched: every one of the seven columns must
      -- still match what the published row held a moment ago for the row to qualify.
      with resynced as (
        update public.loyalty_reward_versions draft
           set internal_name=v_name, customer_name=v_name, description=v_description,
               cost_points=p_points, credit_cents=v_credit_cents,
               estimated_cost_cents=v_credit_cents, image_ref=v_image_ref
         where draft.reward_id=p_reward
           and draft.business_id=p_business
           and draft.config_version_id<>v_active_version
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

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.updated','loyalty_rewards',p_reward,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',v_credit_cents,
      'published_version_synced',v_published_synced,
      'active_config_version_id',v_active_version,
      'draft_versions_synced',v_drafts_synced));

  return jsonb_build_object('status','ok','reward_id',p_reward,'name',v_name,
    'description',v_description,'cost_points',p_points,'credit_cents',v_credit_cents,
    'published_version_synced',v_published_synced);
end
$function$;

comment on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean) is
  'Simplified Points System page gift edit. v423: writes both the live loyalty_rewards row and '
  'the published loyalty_reward_versions row at the business''s active_config_version_id, which '
  'is what customer_get_reward_catalog and app.redeem_reward_core actually read.';

-- ============================================================================================
-- 3. HYGIENE — GRANTS (unrelated to the defect above; same module, same review)
-- ============================================================================================
-- 3a. v326a intended to strip anon EXECUTE from the gift RPCs, but it named
-- business_create_reward_v326(uuid, uuid, text, integer, integer) — the 5-arg signature v343
-- replaced with a 7-arg one. A REVOKE against a signature that no longer exists cannot fail
-- loudly and cannot help. Production proacl before this migration, read from pg_proc:
--   business_create_reward_v326(uuid,uuid,text,integer,integer,text,text)
--     {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
--   business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean)
--     {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- Both still anon-executable, unlike every comparable owner-only write in this module. The
-- internal app.c45_owner_loyalty_write check already refuses a real anonymous caller with 42501;
-- this is the defence in depth v326a was reaching for, aimed at the signatures that exist.
revoke execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text) from public, anon;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text) to authenticated, service_role;

revoke execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean) from public, anon;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean) to authenticated, service_role;

-- 3b. Surplus anon DML on five loyalty relations. Each was verified in prod against
-- information_schema.role_table_grants before being listed here, and each carries anon INSERT,
-- UPDATE and DELETE (bringback_campaigns_v361, bringback_grants_v361 and the
-- client_points_balance view additionally carry anon TRUNCATE). None of them has a single RLS
-- policy that admits anon or public for a write — pg_policies shows only two SELECT policies
-- across the set — so nothing anon can do today survives RLS, and nothing legitimate depends on
-- these grants. TRUNCATE is revoked uniformly: revoking a privilege that was never held is a
-- no-op, not an error. anon SELECT and the authenticated grants are deliberately untouched.
revoke insert, update, delete, truncate on public.bringback_campaigns_v361 from anon;
revoke insert, update, delete, truncate on public.bringback_grants_v361 from anon;
revoke insert, update, delete, truncate on public.client_points_balance from anon;
revoke insert, update, delete, truncate on public.points_batches from anon;
revoke insert, update, delete, truncate on public.reward_grants from anon;

commit;
