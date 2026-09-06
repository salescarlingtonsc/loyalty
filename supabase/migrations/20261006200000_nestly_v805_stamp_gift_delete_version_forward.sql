-- nestly_v805 — deleting a stamp gift stops paying out mid-card (audit F038).
--
-- SYMPTOM, proven against production on 2026-09-02 inside a rolled-back transaction (a scratch
-- stamps tenant, one customer with 4 of 5 stamps and a "Free Coffee" gift at stamp 3):
--
--   before delete: app.reward_availability_v432 -> available_at_counter
--   after  delete: ABSENT
--   live row:      active=false paused=false
--   version rows:  the row on the customer's PINNED (and still active) config version: active=true
--   active config version: unchanged — no new version was ever published
--   pinned redeem: app.redeem_reward_core -> "reward not found or inactive"
--
-- The customer was one stamp short of a gift they had been collecting toward. The owner pressed
-- Delete and it vanished from their card, from the counter's list and from the redeem path, in
-- the same instant, for every customer at once.
--
-- CAUSE. public.business_delete_reward_v326 writes `update public.loyalty_rewards set
-- active=false` on the LIVE row and syncs only an OPEN DRAFT's version row. It never versions
-- forward. Every stamp reader then gates on that live row:
--
--   app.reward_availability_v432        arm 0 join `live.active`, arm 1 (survivors) join `live.active`
--   app.redeem_reward_core              `if not v_reward.active then raise`
--   public.customer_get_stamp_card_v323 `exists (... live.active ...)` (nestly_v475)
--   public.customer_create_redemption_intent_v89  `reward.active and not reward.paused`
--   app.stamp_reward_expire_due_v464    join `live.active`
--
-- That is the exact defect class nestly_v433 fixed for EDITS and nestly_v414/v433 fixed for the
-- card length: an owner action rewriting the configuration a customer's open card is pinned to
-- (app.stamp_cycle_version_v416). Rule 1, locked by the owner on 2026-08-22: once a customer
-- starts a stamp card cycle, the complete configuration for that cycle is immutable for that
-- customer. Removing a gift is a configuration change like any other; it belongs to the NEXT
-- card, not to the one in the customer's hand.
--
-- FIX, in two halves that only work together.
--
--   A. THE WRITER versions forward, reusing v433's begin/commit verbatim — the same pair
--      business_update_reward_v326 and business_set_stamp_card_length_v414 already use. The
--      gift's version row is deactivated on the DRAFT, and the draft is published. New cards pin
--      to the new version and never carry the gift; open cards keep resolving the version they
--      started under, which still does. Because commit PUBLISHES, the delete now passes the same
--      stamps validation a Go-live does: taking the LAST gift off the card pends with
--      `stamp_final_gift_missing` instead of silently leaving a live stamp card that
--      publish_loyalty_config would refuse. No refusal is weakened anywhere; one is added.
--
--   B. THE READERS stop treating the live row's `active=false` as a veto for a stamp gift a
--      pinned cycle still carries. They must, because publish_loyalty_config's live-row sync
--      (`update public.loyalty_rewards r set ... active=rv.active ... where rv.config_version_id
--      = p_version`) sets active=false the moment the withdrawal publishes — which is correct for
--      the owner's list, the catalogue and every new card, and wrong for exactly one reader
--      question: "is this gift still on the card this customer started?"
--
-- HOW A WITHDRAWAL IS TOLD APART FROM A LEGACY DELETE, and why a new column rather than
-- inference. After either one the live row reads active=false while older published version rows
-- still read active=true, so the two states are indistinguishable from the version rows alone. A
-- reader that simply relaxed `live.active` would RESURRECT every gift deleted before today for
-- any customer pinned to a version that predates the delete. public.loyalty_rewards gains
-- `withdrawn_at timestamptz`, written by this one route; NULL means "deleted the old way, stays
-- deleted". Fail closed: the new state is opt-in and only this migration's writer creates it.
--
-- ONE AUTHORITY FOR THE PREDICATE. app.reward_live_on_offer_v805(active, withdrawn_at, is_stamp)
-- is the single place that says what "still on offer" means; all five readers call it, so the
-- rule cannot drift between the card, the counter, the customer's QR and the expiry sweep — the
-- disagreement nestly_v475 and nestly_v432 exist to prevent.
--
-- SCOPE, deliberately narrow:
--   * POINTS gifts are untouched. They carry no cycle pin (their version is always the business's
--     active_config_version_id), so a delete has nothing to be mid-way through. The immediate
--     branch below is byte-identical to what is running today, draft sync included.
--   * A stamp gift on a stopped stamps programme, or a business that has never published, also
--     takes the immediate branch — the same predicate business_update_reward_v326 uses to decide
--     whether to split (`spine.kind='stamps' and spine.active`, non-null active version). This is
--     the "a gift no customer can be mid-card on may still be removed outright" case the existing
--     code already distinguishes; nestly_v495 already withdraws a stopped programme's rescue.
--   * `paused` is NOT cleared in the version-forward branch (the immediate branch still clears it,
--     as it always has). Clearing it would un-pause a paused gift for every pinned card at the
--     moment it was deleted — a gift reappearing because it was removed.
--   * app.c45_base_actionable_wallet_card is knowingly left alone. It resolves reward versions at
--     businesses.active_config_version_id rather than at the cycle pin, so the wallet hero card
--     already shows the wrong version after ANY stamp edit (register F128). Withdrawing a gift
--     removes it from that hero for pinned customers too. Fixing the hero's version resolution is
--     F128's change, not this one, and doing it here would put a second pin authority in the tree.
--
-- COLUMN GRANT. public.loyalty_rewards carries COLUMN-level privileges, so a new column is
-- invisible to the API by default — and app/app.js reads this table with `select('*')`, which
-- PostgREST expands server-side and which would then fail with "permission denied for column".
-- SELECT is granted; INSERT/UPDATE deliberately are not, so withdrawn_at has exactly one writer.
--
-- ALL FIVE READERS ARE SPLICED, not retyped (the nestly_v513 rule, the v542/v680 method):
-- pg_get_functiondef + an anchor that must match exactly once, so a drifted body fails loudly
-- instead of being silently reverted to a stale copy.
--
-- REVERSIBLE: re-apply the v326 body from db/migrations/20260815_nestly_v326_points_gift_lifecycle.sql
-- and re-splice each anchor back (drop the app.reward_live_on_offer_v805 call, restore `live.active`
-- / `not v_reward.active`). The column may stay; with no reader consulting it, it is inert.

begin;

set search_path to 'pg_catalog','public','app','pg_temp';

-- =============================================================================================
-- 1. THE MARK. One writer (§3), five readers (§4), no inference.
-- =============================================================================================
alter table public.loyalty_rewards
  add column if not exists withdrawn_at timestamptz;

comment on column public.loyalty_rewards.withdrawn_at is
  'nestly_v805: set when business_delete_reward_v326 withdrew this stamp gift version-forward. '
  'active=false + withdrawn_at is not null means "gone from the catalogue and from every new '
  'stamp card, still claimable on a cycle pinned to a version that carries it". NULL means the '
  'gift was deleted before v805 (or is a points gift) and stays deleted for everyone.';

grant select (withdrawn_at) on public.loyalty_rewards to authenticated, service_role;

-- The column has exactly ONE writer, enforced rather than asserted: table privileges differ
-- between production (authenticated holds SELECT only) and the schema-snapshot cluster the
-- executed suites run on, so a privilege check alone would prove different things in the two
-- places. publish_loyalty_config and every other writer of this table leave withdrawn_at alone
-- and pass straight through.
create or replace function app.loyalty_reward_withdrawn_guard_v805()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op = 'INSERT' then
    if new.withdrawn_at is not null then
      raise exception 'a new gift cannot be created already withdrawn'
        using errcode='restrict_violation';
    end if;
    return new;
  end if;
  if new.withdrawn_at is distinct from old.withdrawn_at
     and nullif(current_setting('app.v805_withdraw', true), '') is distinct from new.id::text then
    raise exception 'loyalty_rewards.withdrawn_at is written only by business_delete_reward_v326'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;

revoke all on function app.loyalty_reward_withdrawn_guard_v805() from public, anon, authenticated;

drop trigger if exists trg_loyalty_rewards_withdrawn_v805 on public.loyalty_rewards;
create trigger trg_loyalty_rewards_withdrawn_v805
before insert or update on public.loyalty_rewards
for each row execute function app.loyalty_reward_withdrawn_guard_v805();

-- =============================================================================================
-- 2. THE PREDICATE. The one authority on "is this live row still on offer".
--    p_is_stamp mirrors app.reward_availability_v432's own `shape.is_stamp`: the reward's
--    programme IS the business's stamps spine, regardless of whether that spine is running (the
--    running check is a separate question every caller already asks separately).
-- =============================================================================================
create or replace function app.reward_live_on_offer_v805(
  p_active boolean, p_withdrawn_at timestamptz, p_is_stamp boolean
) returns boolean
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(p_active, false)
      or (p_withdrawn_at is not null and coalesce(p_is_stamp, false))
$$;

comment on function app.reward_live_on_offer_v805(boolean, timestamptz, boolean) is
  'nestly_v805: is this loyalty_rewards row still on offer? Active rows always are. A withdrawn '
  'stamp gift also is, for whoever asks about a cycle pinned to a version that still carries it '
  '- the caller''s own version join decides that. Paused is a separate flag and is not read here.';

revoke all on function app.reward_live_on_offer_v805(boolean, timestamptz, boolean)
  from public, anon, authenticated;

-- =============================================================================================
-- 3. THE WRITER. Restated in full (it is short, and both branches must be readable side by
--    side). The immediate branch is the v326 body unchanged.
-- =============================================================================================
create or replace function public.business_delete_reward_v326(p_business uuid, p_reward uuid)
returns jsonb
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
  v_draft_rows integer := 0;
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

  select active_config_version_id into v_active_version
    from public.businesses where id=p_business for share;

  -- nestly_v805: the same question business_update_reward_v326 asks before it splits.
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

  if v_split then
    -- Withdraw the gift from the NEXT version only. The live row is NOT switched off here:
    -- publish_loyalty_config's live-row sync does that when the draft actually publishes, so a
    -- delete that pends (see below) leaves the gift exactly as it was.
    update public.loyalty_reward_versions set active=false
     where reward_id=p_reward and business_id=p_business
       and config_version_id=v_target and active;
    get diagnostics v_draft_rows = row_count;
  end if;

  if v_split and v_draft_rows = 0 then
    -- The clone carries no row for this gift (it exists live but not in the version the draft was
    -- cloned from), so version-forwarding it would publish a version that does not mention it and
    -- change nothing. Fall back to the immediate delete rather than report a withdrawal that did
    -- not happen.
    v_split := false;
  end if;

  if v_split then
    perform set_config('app.v805_withdraw', p_reward::text, true);
    update public.loyalty_rewards
       set withdrawn_at = coalesce(withdrawn_at, now())
     where id=p_reward and business_id=p_business;
    perform set_config('app.v805_withdraw', '', true);
    v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
  else
    update public.loyalty_rewards set active=false, paused=false
     where id=p_reward and business_id=p_business;

    -- V326: keep any currently OPEN draft's own version row in sync so that publishing an
    -- unrelated draft later cannot resurrect this delete. A *published* version row cannot be
    -- touched here (trg_loyalty_reward_versions_immutable) and does not need to be — nothing reads
    -- loyalty_reward_versions.active off a published row as a delete gate outside of the redeem
    -- paths, which now check loyalty_rewards.active/paused directly (see app.redeem_reward_core).
    select id into v_draft_version from public.firm_config_versions
     where business_id=p_business and status='draft' limit 1;
    if v_draft_version is not null then
      update public.loyalty_reward_versions set active=false
       where reward_id=p_reward and business_id=p_business
         and config_version_id=v_draft_version and active;
    end if;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.deleted','loyalty_rewards',p_reward,
    jsonb_build_object('name',coalesce(v_row.customer_name,v_row.name),
      'version_split',v_split,
      'target_version_id',v_target,
      'publish_status',coalesce(v_commit->>'publish_status','published'),
      'blockers',coalesce(v_commit->'blockers','[]'::jsonb)));

  return jsonb_build_object('status','ok','reward_id',p_reward,
    'mode', case when v_split then 'withdrawn' else 'deleted' end,
    'version_split', v_split,
    'publish_status', coalesce(v_commit->>'publish_status','published'),
    'blockers', coalesce(v_commit->'blockers','[]'::jsonb));
end
$function$;

revoke all on function public.business_delete_reward_v326(uuid, uuid) from public, anon;
grant execute on function public.business_delete_reward_v326(uuid, uuid) to authenticated;
grant execute on function public.business_delete_reward_v326(uuid, uuid) to service_role;

comment on function public.business_delete_reward_v326(uuid, uuid) is
  'v805: remove a gift. A stamp gift on a running stamp programme is withdrawn VERSION-FORWARD '
  '(v433 begin/commit): it leaves the next published version, and a customer whose open cycle is '
  'pinned to a version that still carries it keeps claiming it until that cycle ends. Publishing '
  'runs the full stamps validation, so taking the last gift off the card pends with blockers '
  'instead of leaving an unpublishable card. Anything else deletes outright, exactly as before.';

-- =============================================================================================
-- 4. THE READERS. Spliced with anchors reproduced inside their replacements.
-- =============================================================================================

-- 4a. app.reward_availability_v432 — the ONE availability core (staff list == customer list).
do $splice$
declare
  v_def text; v_new text;
  v_arm0_join constant text :=
'      join public.loyalty_rewards live
        on live.business_id = business.id
       and live.active
       and not live.paused';
  v_arm0_join_new constant text :=
'      join public.loyalty_rewards live
        on live.business_id = business.id
       and not live.paused';
  v_arm0_where constant text :=
'      where live.programme_id is not null';
  v_arm0_where_new constant text :=
'      where app.reward_live_on_offer_v805(live.active, live.withdrawn_at, shape.is_stamp)
        and live.programme_id is not null';
  v_arm1 constant text :=
'       and live.business_id = p_business
       and live.active
       and not live.paused';
  v_arm1_new constant text :=
'       and live.business_id = p_business
       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and not live.paused';
begin
  v_def := pg_get_functiondef(
    'app.reward_availability_v432(uuid,uuid,timestamptz)'::regprocedure);
  if position('reward_live_on_offer_v805' in v_def) > 0 then
    raise notice 'nestly_v805: reward_availability_v432 already asks the v805 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_arm0_join, ''))) / nullif(length(v_arm0_join),0) <> 1
       or (length(v_def) - length(replace(v_def, v_arm0_where, ''))) / nullif(length(v_arm0_where),0) <> 1
       or (length(v_def) - length(replace(v_def, v_arm1, ''))) / nullif(length(v_arm1),0) <> 1 then
      raise exception 'nestly_v805: an anchor did not match exactly once in reward_availability_v432 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_arm0_join, v_arm0_join_new);
    v_new := replace(v_new, v_arm0_where, v_arm0_where_new);
    v_new := replace(v_new, v_arm1, v_arm1_new);
    if v_new = v_def then
      raise exception 'nestly_v805: splice produced no change in reward_availability_v432'
        using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.reward_availability_v432(uuid,uuid,timestamptz)
  from public, anon, authenticated;

-- 4b. app.redeem_reward_core — the counter. The live-row veto becomes the v805 predicate; the
--     version check further down (`if v_version.id is null or not v_version.active`) is what
--     actually decides, and it already reads the PINNED version for a stamps programme.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'  if not v_reward.active then raise exception ''reward not found or inactive''; end if;';
  v_inject constant text :=
'  if not app.reward_live_on_offer_v805(v_reward.active, v_reward.withdrawn_at,
       exists (select 1 from public.business_programmes spine
                where spine.id = v_reward.programme_id and spine.business_id = p_business
                  and spine.kind = ''stamps'')) then
    raise exception ''reward not found or inactive''; end if;';
begin
  v_def := pg_get_functiondef(
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure);
  if position('reward_live_on_offer_v805' in v_def) > 0 then
    raise notice 'nestly_v805: redeem_reward_core already asks the v805 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v805: anchor did not match exactly once in redeem_reward_core — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;

-- 4c. public.customer_get_stamp_card_v323 — the card the customer is holding. nestly_v475 added
--     this predicate so the card could not promise what the counter refuses; the counter now
--     honours the withdrawn gift on a pinned cycle, so the card must show it again.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'                      and live.active
                      and not coalesce(live.paused, false))';
  v_inject constant text :=
'                      and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
                      and not coalesce(live.paused, false))';
begin
  v_def := pg_get_functiondef('public.customer_get_stamp_card_v323(text)'::regprocedure);
  if position('reward_live_on_offer_v805' in v_def) > 0 then
    raise notice 'nestly_v805: customer_get_stamp_card_v323 already asks the v805 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v805: anchor did not match exactly once in customer_get_stamp_card_v323 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

-- 4d. public.customer_create_redemption_intent_v89 — the customer's own QR. Only the withdrawn
--     case changes: an ACTIVE reward still resolves its version at businesses.active_config_
--     version_id exactly as before, so nothing about a normal claim moves.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'    select * into v_reward from public.loyalty_rewards reward
    where reward.id=p_reward and reward.business_id=p_business and reward.active and not reward.paused;
    if not found then
      raise exception ''reward is unavailable'' using errcode=''22023'';
    end if;
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    join public.businesses business on business.id=reward_version.business_id
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id=business.active_config_version_id
      and reward_version.active;';
  v_inject constant text :=
'    select * into v_reward from public.loyalty_rewards reward
    where reward.id=p_reward and reward.business_id=p_business and not reward.paused
      and app.reward_live_on_offer_v805(reward.active, reward.withdrawn_at,
            exists (select 1 from public.business_programmes spine
                     where spine.id=reward.programme_id and spine.business_id=p_business
                       and spine.kind=''stamps''));
    if not found then
      raise exception ''reward is unavailable'' using errcode=''22023'';
    end if;
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_reward.active
            then (select business.active_config_version_id from public.businesses business
                   where business.id=p_business)
            else app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id) end
      and reward_version.active;';
begin
  v_def := pg_get_functiondef(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  if position('reward_live_on_offer_v805' in v_def) > 0 then
    raise notice 'nestly_v805: customer_create_redemption_intent_v89 already asks the v805 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v805: anchor did not match exactly once in customer_create_redemption_intent_v89 — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    execute v_new;
  end if;
end
$splice$;
revoke all on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  to authenticated, service_role;

-- 4e. app.stamp_reward_expire_due_v464 — a gift that is still claimable must still be able to
--     expire. Leaving this reader behind would make a withdrawn gift the one reward on the card
--     the expiry sweep can never record.
do $splice$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'       and live.business_id = p_business
       and live.active
       and not live.paused';
  v_inject constant text :=
'       and live.business_id = p_business
       and app.reward_live_on_offer_v805(live.active, live.withdrawn_at, true)
       and not live.paused';
begin
  v_def := pg_get_functiondef('app.stamp_reward_expire_due_v464(uuid,uuid,uuid)'::regprocedure);
  if position('reward_live_on_offer_v805' in v_def) > 0 then
    raise notice 'nestly_v805: stamp_reward_expire_due_v464 already asks the v805 predicate, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v805: anchor did not match exactly once in stamp_reward_expire_due_v464 — body drifted'
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
-- 5. Prove the change took, in the transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_missing text[] := '{}';
  v_name text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='loyalty_rewards'
                    and column_name='withdrawn_at') then
    raise exception 'nestly_v805: loyalty_rewards.withdrawn_at was not created' using errcode='XX001';
  end if;
  if not exists (select 1 from information_schema.column_privileges
                  where table_schema='public' and table_name='loyalty_rewards'
                    and column_name='withdrawn_at' and grantee='authenticated'
                    and privilege_type='SELECT') then
    raise exception 'nestly_v805: authenticated cannot SELECT withdrawn_at — select(*) reads of loyalty_rewards would fail'
      using errcode='XX001';
  end if;
  if not exists (select 1 from pg_trigger t
                  where t.tgrelid='public.loyalty_rewards'::regclass
                    and t.tgname='trg_loyalty_rewards_withdrawn_v805'
                    and not t.tgisinternal) then
    raise exception 'nestly_v805: withdrawn_at has no write guard — it must have exactly one writer'
      using errcode='XX001';
  end if;
  foreach v_name in array array[
    'app.reward_availability_v432(uuid,uuid,timestamptz)',
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
    'public.customer_get_stamp_card_v323(text)',
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
    'app.stamp_reward_expire_due_v464(uuid,uuid,uuid)'
  ] loop
    if position('reward_live_on_offer_v805' in pg_get_functiondef(v_name::regprocedure)) = 0 then
      v_missing := v_missing || v_name;
    end if;
  end loop;
  if array_length(v_missing,1) > 0 then
    raise exception 'nestly_v805: these readers still gate on the live row alone: %',
      array_to_string(v_missing,', ') using errcode='XX001';
  end if;
  if position('stamp_config_edit_begin_v433' in pg_get_functiondef(
       'public.business_delete_reward_v326(uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v805: deleting a stamp gift still does not version forward'
      using errcode='XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema='app' and routine_name='reward_live_on_offer_v805'
                and grantee in ('anon','authenticated','PUBLIC')) then
    raise exception 'nestly_v805: the predicate is reachable from the API' using errcode='XX001';
  end if;
end
$verify$;

commit;
