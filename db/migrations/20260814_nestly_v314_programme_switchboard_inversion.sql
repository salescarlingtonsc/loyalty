-- nestly_v314_programme_switchboard_inversion
--
-- W6 INCREMENT 1, PART b of b — THE INVERSION (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md;
-- W6 build brief [INCREMENT-1 BRIEF: SERVER] §v314). Applies immediately after
-- nestly_v313_reward_programme_identity and requires it.
--
-- WHAT THIS IS. Until now public.business_programmes was a DERIVED PROJECTION: four one-way sync
-- triggers recomputed it from loyalty_programs.active / .loyalty_model, businesses.points_mode,
-- the presence of loyalty_tiers rows and referral_programs.enabled. This migration turns the
-- arrow around. The spine becomes the AUTHORITY — one owner-callable RPC writes it, the sync
-- triggers are dropped, and the consumers that used to ask the legacy columns "is this programme
-- running?" now ask the spine. loyalty_model and loyalty_programs.active stop being switches and
-- become what they always described: SETTINGS.
--
-- WHAT "PAUSED" MEANS AFTER THIS MIGRATION — THE COMPLETE RULE, STATED ONCE.
--   A programme is PAUSED when its row in public.business_programmes has active=false, and that
--   is the ONLY thing pausing means. It is one flag and it governs BOTH directions:
--     * accrual   — app.on_sale_recorded loops over active accruing spine rows only, so a paused
--                   programme earns nothing (consumers 1 and 2 below);
--     * spending  — app.redeem_reward_core refuses a reward whose own programme row is off, and
--                   its loyalty_programs lookup no longer carries `and active` at all
--                   (consumer 5, all three sites), so the settings row cannot refuse a
--                   redemption on its own;
--     * quoting   — public.customer_create_redemption_intent_v89 and
--                   public.customer_get_business_actions_v89 hide and refuse the same rewards
--                   (consumers 4 and 6), so a customer is never quoted a gift the counter will
--                   decline.
--   The first cut of this migration got HALF of that: it dropped `lp.active` from the earn gate
--   (consumer 1) but left `and active limit 1` on redeem_reward_core's row lookup. A paused firm
--   therefore accrued points its customers could never spend — liability with no exit — and, from
--   the other side, publishing a config with the programme Status set to Paused earned anyway,
--   because the earn gate was no longer reading that flag and nothing had turned the spine off.
--   Both are one bug: pause was two truths. It is one truth now, and the browser writes it
--   through public.set_programmes_v314 like every other switch (app/app.js
--   programmeSwitchSetV314 turns every switch in the chosen model's set OFF when the owner keeps
--   it paused).
--
-- WHY IT IS ONE TRANSACTION. Any window in which both the sync triggers and the new writer exist
-- is a window in which an owner's switch is silently reverted by the next publish
-- (publish_loyalty_config updates loyalty_programs on every publish, v55:711). Any window in
-- which neither exists is a window in which the four flags are frozen. So: triggers out,
-- consumers flipped, writer in — one commit, no window.
--
-- NON-GOAL, STATED SO A LATER READER DOES NOT "TIDY IT UP": nothing here touches
-- loyalty_programs.tier_basis, loyalty_program_versions.tier_basis, expiry_mode, expiry_days or
-- any other expiry knob. OWNER AMENDMENT 2026-08-14: tiered membership co-exists with the other
-- three programmes and the basis CHOICE survives; W5 verified both non-points branches of
-- app.loyalty_tier_for and both expiry modes are logic-identical to v148
-- (V311-V312-W5-MONEY-WAVE-ACCEPTANCE.md:20-28). The tier programme gains an independent ON/OFF
-- switch here and nothing else.
--
-- THE SEEDER — the most dangerous thing in this file. v308:395-401 attached the businesses sync
-- trigger with the comment "INSERT creates the four rows for a brand-new tenant". Dropping it
-- without a replacement means every business created after this migration has ZERO spine rows,
-- and every consequence is silent: app.on_sale_recorded's loop iterates nothing so the firm never
-- earns; app.reward_default_programme_v314 returns null so authoring a reward raises 23514;
-- points_ledger.programme_id has nowhere legal to point. A new tenant would be dead on arrival
-- with no error at signup. §1b replaces it with a SEED-ONLY AFTER INSERT trigger, and
-- set_programmes_v314 self-heals a firm that somehow lacks the rows.
--
-- THE points_mode TRIPWIRE SWALLOWS, IT DOES NOT RAISE (brief R4, a deliberate and recorded
-- weakening of the design contract). /app-*.js is Cloudflare-pinned for about four hours
-- (scripts/quality/stamp-app-bundle.mjs), so for that long after deploy the OLD bundle still
-- PATCHes businesses.points_mode after every wizard publish. A raising tripwire would turn that
-- into a visible "Published. The tier switch could not be applied…" error for every owner who
-- publishes in the window. So the column is silently pinned and one audit_log row
-- (POINTS_MODE_WRITE_SUPPRESSED_V314) is written instead. Increment 9 upgrades it to a raise
-- once that table proves zero writers remain.
--
-- ROLLBACK, SAID OUT LOUD: re-attaching the four v308 sync triggers and re-running the sync
-- DISCARDS every switch an owner made after this migration, because the sync recomputes from the
-- legacy columns. That is the rollback. It belongs in this header and in the acceptance doc, not
-- in an incident.
--
-- V308 STANDING INVARIANT 2 IS RETIRED HERE. business_programmes_sync_loyalty_tiers_v308 was the
-- only DEFERRABLE INITIALLY DEFERRED trigger in the set, and the invariant existed to explain why
-- the spine converges at COMMIT inside a ladder edit. With that trigger dropped nothing defers,
-- and the spine is correct statement-by-statement again. Recorded rather than left dangling.
--
-- Nothing here writes credit_ledger, points_ledger, points_batches or sales. It writes
-- public.business_programmes (through one gated RPC), one new idempotency receipt table, and
-- audit_log. Pot movement is delegated in full to app.enqueue_programme_pot_migration_v312 —
-- V311/V312 standing invariant 2, honoured rather than re-implemented.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition (same cure as v313's prelude, same
-- 2026-08-14 production incident). This migration takes AccessExclusiveLocks on
-- businesses and loyalty_programs via its trigger DDL; the live media pipeline
-- (business_publish_media_replacement_v95, a continuous PostgREST retry stream)
-- holds storage.objects while reading tenant tables inside one transaction.
-- Everything contested is taken up front in one ordered acquisition so no cycle
-- can form. storage.objects is conditional because rigs replay app/public only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v314_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v314_prelock$;

lock table public.businesses, public.loyalty_programs, public.loyalty_tiers,
           public.referral_programs
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- 0. Preconditions. Fail closed. v314 does not ASSUME W5 or v313 — it proves them.
-- ---------------------------------------------------------------------------

do $v314_pins$
declare
  v_osr text;
  v_caps_norm text;
  v_catalog_norm text;
  v_core text;
  v_intent_norm text;
  v_scan_v117 text;
  v_count bigint;
begin
  if to_regprocedure('public.set_programmes_v314(uuid,jsonb,uuid)') is not null then
    raise exception 'v314 is already applied (public.set_programmes_v314 exists)'
      using errcode = '23514';
  end if;

  -- (a) W5 landed: the tripwire is gone, the per-programme arbiter is authoritative.
  if exists (select 1 from pg_trigger
              where tgname = 'business_programmes_exclusive_accrual_v308' and not tgisinternal) then
    raise exception 'v314: the v308 exclusive-accrual tripwire is still attached (W5 incomplete)'
      using errcode = '23514';
  end if;
  if to_regclass('public.points_earn_once_per_sale_per_programme') is null then
    raise exception 'v314: the per-programme earn arbiter index is absent (W5 incomplete)'
      using errcode = '42P01';
  end if;
  if to_regclass('public.points_earn_once_per_sale') is not null then
    raise exception 'v314: the v2 single-earn index still exists (W5 incomplete)'
      using errcode = '23514';
  end if;

  -- (b) v313 landed: the reward knows its programme.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name in ('loyalty_rewards','loyalty_reward_versions')
       and column_name = 'programme_id' and is_nullable = 'YES'
  ) or not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_rewards'
       and column_name = 'programme_id'
  ) then
    raise exception 'v314: loyalty_rewards/loyalty_reward_versions.programme_id is not NOT NULL '
      '(apply v313 first)' using errcode = '23514';
  end if;

  -- (c) the money is coherent before authority moves.
  select count(*) into strict v_count from app.detect_programme_pot_split_v312();
  if v_count <> 0 then
    raise exception 'v314: the W5 pot-split detector is not empty (% rows)', v_count
      using errcode = '23514';
  end if;

  -- (d) THE PIN TABLE. Comment-normalised md5 where the body carries full-line comments,
  --     because a production apply strips them and a byte-faithful one does not.
  --
  --     on_sale_recorded / capabilities  = the W5 production post-state
  --                                        (V311-V312-W5-MONEY-WAVE-ACCEPTANCE.md:93-113).
  --     redeem_reward_core / intent_v89  = v313's post-apply values. The W5 fingerprints are
  --                                        stale the moment v313 lands; these are what v313
  --                                        deterministically produces from them.
  --     merchant_scan_redemption_qr_v117 = READ, not pinned. Its live body carries v89 + v117
  --                                        lineage that this repo cannot reproduce byte-exactly,
  --                                        so the counted needles in §5 are its fail-closed guard.
  select md5(p.prosrc) into strict v_osr
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_osr <> 'aac80aec8f893ed6c883020aff5da090' then
    raise exception 'v314: app.on_sale_recorded is not the W5 post-state body (md5=%)', v_osr
      using errcode = '23514';
  end if;

  select md5(coalesce((
           select string_agg(split.line, chr(10) order by split.ord)
             from regexp_split_to_table(p.prosrc, chr(10)) with ordinality as split(line, ord)
            where btrim(split.line) not like '--%'), ''))
    into strict v_caps_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_portal_capabilities';
  if v_caps_norm <> '735e2b2b885f12937c73ff0aae827085' then
    raise exception 'v314: customer_portal_capabilities is not the W5 post-state body '
      '(normalised md5=%)', v_caps_norm using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_core
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if v_core <> '4b994c9b8865b5fbf72383db484500d3' then
    raise exception 'v314: app.redeem_reward_core is not v313''s post-apply body (md5=%)', v_core
      using errcode = '23514';
  end if;

  select md5(coalesce((
           select string_agg(split.line, chr(10) order by split.ord)
             from regexp_split_to_table(p.prosrc, chr(10)) with ordinality as split(line, ord)
            where btrim(split.line) not like '--%'), ''))
    into strict v_intent_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_create_redemption_intent_v89';
  if v_intent_norm <> 'bf653a90adbe617b9b84f4942529bacc' then
    raise exception 'v314: customer_create_redemption_intent_v89 is not v313''s post-apply body '
      '(normalised md5=%)', v_intent_norm using errcode = '23514';
  end if;

  -- Recorded, not enforced: v314 does not touch the catalogue function, and its live md5 and its
  -- canonical replay have been known to differ since v310 (v310:213-220 records both).
  select md5(coalesce((
           select string_agg(split.line, chr(10) order by split.ord)
             from regexp_split_to_table(p.prosrc, chr(10)) with ordinality as split(line, ord)
            where btrim(split.line) not like '--%'), ''))
    into strict v_catalog_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if v_catalog_norm not in (
       '07897b24b70da71c5a954d748cc0df3d',   -- W5 production post-state
       'd7c3e72636fa40e562937cc877a3313d'    -- canonical replay of the same lineage
     ) then
    raise notice 'v314: customer_get_reward_catalog normalised md5=% is neither the recorded '
      'production value nor the canonical replay; v314 does not touch it', v_catalog_norm;
  end if;

  select md5(p.prosrc) into strict v_scan_v117
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'merchant_scan_redemption_qr_v117';

  raise notice
    'v314 predecessor pins met: on_sale_recorded=%, capabilities(norm)=%, redeem_reward_core=%, '
    'intent_v89(norm)=%, catalog(norm)=%, merchant_scan_v117(read)=%',
    v_osr, v_caps_norm, v_core, v_intent_norm, v_catalog_norm, v_scan_v117;
end
$v314_pins$;

-- The last thing the pins can check is that nothing has switched yet — but the detector that
-- answers it does not exist until §7. It is created there and asserted empty in §9, which is the
-- same guarantee one statement later.

-- ---------------------------------------------------------------------------
-- 1. Freeze the derivation. Drop the four v308 sync triggers BY NAME.
--
--    By name, not by function: `drop function ... cascade` would take whatever else someone had
--    attached, and the four names are the contract V308 wrote down (v308:397-448).
-- ---------------------------------------------------------------------------

drop trigger if exists business_programmes_sync_businesses_v308        on public.businesses;
drop trigger if exists business_programmes_sync_loyalty_programs_v308  on public.loyalty_programs;
drop trigger if exists business_programmes_sync_loyalty_tiers_v308     on public.loyalty_tiers;
drop trigger if exists business_programmes_sync_referral_programs_v308 on public.referral_programs;

revoke all privileges on function app.sync_business_programmes_v308(uuid)
  from public, anon, authenticated, service_role;

comment on function app.sync_business_programmes_v308(uuid) is
  'v308 W2 legacy->spine recompute, RETIRED AT v314. Its four triggers are dropped and its '
  'EXECUTE privilege is revoked from every role including service_role: after the inversion the '
  'spine is the AUTHORITY and running this would overwrite an owner''s switches with a value '
  'derived from settings. Kept installed, and only installed, because the documented rollback is '
  '"re-attach the four triggers and run this once per business" — which discards every '
  'post-inversion switch, deliberately and knowingly.';

comment on function app.business_programmes_sync_trigger_v308() is
  'v308 W2 trigger shim, RETIRED AT v314 with the four triggers that called it. Kept installed '
  'so the rollback is `create trigger`, not `create function`.';

-- ---------------------------------------------------------------------------
-- 1b. THE SEEDER. A brand-new tenant still gets its four rows.
--
--     Provably a no-op versus today for the only path that creates a business:
--     public.create_business inserts public.businesses FIRST
--     (supabase/migrations/20260721000004_frenly_v25_draft_onboarding_loyalty.sql:53) and only
--     then loyalty_programs with active=false (:71-77), so app.business_programmes_v307 already
--     answered all-four-false at INSERT time and the v308 trigger's later re-syncs changed
--     nothing. The OBSERVABLE change is that the subsequent loyalty_programs insert no longer
--     re-derives the spine — which is exactly right in the switchboard world, and is named here
--     rather than discovered.
-- ---------------------------------------------------------------------------

create or replace function app.seed_business_programmes_v314()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.business_programmes (business_id, kind, active, sort, activated_at)
  select new.id,
         model.kind,
         model.running,
         (case model.kind
            when 'points' then 1
            when 'tiers' then 2
            when 'stamps' then 3
            when 'referral' then 4
          end)::smallint,
         case when model.running then now() end
    from app.business_programmes_v307(new.id) model
  on conflict (business_id, kind) do nothing;
  return null;
end
$$;

revoke all privileges on function app.seed_business_programmes_v314()
  from public, anon, authenticated;

comment on function app.seed_business_programmes_v314() is
  'v314 W6i1 SEED-ONLY replacement for the businesses arm of the v308 sync. Creates the four '
  'spine rows for a brand-new tenant from app.business_programmes_v307 and NEVER updates them '
  'again — after the inversion an update would overwrite an owner''s switch with a legacy '
  'derivation. Without this trigger every business created after v314 would have zero spine rows '
  'and would silently never earn, never redeem and never authorise a reward.';

drop trigger if exists business_programmes_seed_v314 on public.businesses;
create trigger business_programmes_seed_v314
  after insert on public.businesses
  for each row
  execute function app.seed_business_programmes_v314();

-- ---------------------------------------------------------------------------
-- 2. THE ONE INTENDED WRITER.
-- ---------------------------------------------------------------------------

create table if not exists public.programme_switch_operations_v314 (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  idempotency_key uuid not null,
  actor           uuid,
  request_hash    text not null,
  result          jsonb,
  created_at      timestamptz not null default now(),
  unique (business_id, idempotency_key)
);

alter table public.programme_switch_operations_v314 enable row level security;
revoke all privileges on table public.programme_switch_operations_v314
  from public, anon, authenticated;
grant select on table public.programme_switch_operations_v314 to authenticated;

drop policy if exists programme_switch_operations_read on public.programme_switch_operations_v314;
create policy programme_switch_operations_read on public.programme_switch_operations_v314
  for select to authenticated
  using (app.is_salon_member(business_id));
drop policy if exists programme_switch_operations_sa_read
  on public.programme_switch_operations_v314;
create policy programme_switch_operations_sa_read on public.programme_switch_operations_v314
  for select to authenticated
  using (app.is_super_admin());

comment on table public.programme_switch_operations_v314 is
  'v314 W6i1 idempotency receipt for public.set_programmes_v314. One row per (business, '
  'idempotency_key); a double-tapped toggle replays the stored result instead of flipping twice. '
  'Read-only to browsers, exactly like public.business_programmes itself.';

create or replace function public.set_programmes_v314(
  p_business uuid,
  p_switches jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_rows integer;
  v_existing public.programme_switch_operations_v314%rowtype;
  v_kind text;
  v_want boolean;
  v_before boolean;
  v_changes jsonb := '[]'::jsonb;
  v_result jsonb;
  v_points boolean;
  v_stamps boolean;
  v_points_before boolean;
  v_stamps_before boolean;
  v_from uuid;
  v_to uuid;
  v_migration uuid;
begin
  if p_business is null or p_idempotency_key is null then
    raise exception 'business and idempotency key are required' using errcode = '22023';
  end if;
  if p_switches is null or jsonb_typeof(p_switches) <> 'object' then
    raise exception 'switches must be a JSON object' using errcode = '22023';
  end if;
  if jsonb_typeof(p_switches) = 'object' and exists (
    select 1 from jsonb_object_keys(p_switches) key
     where key not in ('points','tiers','stamps','referral')
  ) then
    raise exception 'switches may only name points, tiers, stamps or referral'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_each(p_switches) entry
     where jsonb_typeof(entry.value) <> 'boolean'
  ) then
    raise exception 'every switch must be true or false' using errcode = '22023';
  end if;
  if p_switches = '{}'::jsonb then
    raise exception 'at least one switch is required' using errcode = '22023';
  end if;

  -- The SAME gate publish_loyalty_config uses (v55:682). Owner + loyalty module write + the
  -- module actually enabled on the business. No RLS write policy is added to
  -- public.business_programmes: it stays SELECT-only for authenticated (v308:181-195), and this
  -- definer function is the only door.
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  v_hash := md5(p_business::text || ':' || (
    select coalesce(string_agg(key || '=' || (p_switches ->> key), ',' order by key), '')
      from jsonb_object_keys(p_switches) key
  ));

  insert into public.programme_switch_operations_v314
    (business_id, idempotency_key, actor, request_hash)
  values (p_business, p_idempotency_key, v_actor, v_hash)
  on conflict (business_id, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    select * into strict v_existing from public.programme_switch_operations_v314
     where business_id = p_business and idempotency_key = p_idempotency_key
       for update;
    if v_existing.request_hash is distinct from v_hash then
      raise exception 'idempotency key conflicts with another programme switch'
        using errcode = '23505';
    end if;
    if v_existing.result is not null then
      return v_existing.result;
    end if;
    raise exception 'programme switch already in progress' using errcode = '55P03';
  end if;

  -- V308 STANDING INVARIANT 1, VERBATIM AND WITHOUT EXCEPTION: the businesses row FIRST, then the
  -- spine rows in KIND ORDER. publish_loyalty_config takes the same lock in the same order
  -- (v55:683), so a publish and a switch serialise against each other instead of deadlocking.
  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    raise exception 'business does not exist' using errcode = '42501';
  end if;

  -- The accruing state BEFORE any flip. Read here, under the businesses lock, because the
  -- pot-routing decision below is about MOVEMENT — which programme was carrying the firm's
  -- accrual and which one is carrying it now — and that question cannot be answered from the
  -- after-state alone.
  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points_before, v_stamps_before
    from public.business_programmes spine
   where spine.business_id = p_business;

  -- Self-heal: a firm that somehow lacks its four rows (a pre-v308 restore, a manual delete)
  -- gets them here rather than failing an owner's first switch. Seeded all-false-by-derivation,
  -- exactly as a brand-new tenant is, and then immediately overwritten by the requested set.
  insert into public.business_programmes (business_id, kind, active, sort, activated_at)
  select p_business, model.kind, model.running,
         (case model.kind
            when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 when 'referral' then 4
          end)::smallint,
         case when model.running then now() end
    from app.business_programmes_v307(p_business) model
  on conflict (business_id, kind) do nothing;

  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry
     order by case entry.key
                when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 else 4 end
  loop
    select spine.active into v_before
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = v_kind
       for update;
    if not found then
      raise exception 'business % has no % programme row', p_business, v_kind
        using errcode = 'XX001';
    end if;
    -- A no-op flip writes NOTHING (v308:313's guard, preserved): no dead tuple, no breadcrumb
    -- churn, no audit row. Re-calling with the state a firm is already in is free.
    if v_before is distinct from v_want then
      update public.business_programmes spine
         set active = v_want,
             -- v308:303-311's breadcrumb semantics, reproduced EXACTLY. activated_at moves only
             -- on false->true, deactivated_at only on true->false, and neither is ever cleared.
             -- W4b's running_since / paused_since must keep meaning the same thing across the
             -- inversion or every customer-facing "running since" line silently changes meaning.
             activated_at = case when v_want and not spine.active then now()
                                 else spine.activated_at end,
             deactivated_at = case when spine.active and not v_want then now()
                                   else spine.deactivated_at end
       where spine.business_id = p_business and spine.kind = v_kind;
      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'PROGRAMME_SWITCH_V314', 'business_programmes', spine.id,
             jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want,
                                'source', 'set_programmes_v314')
        from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = v_kind;
    end if;
  end loop;

  -- ---- pot-migration routing (V311/V312 standing invariant 2) ----
  -- THE RULE IS "DID THE ACCRUING IDENTITY MOVE?", NOT "IS ONE LEFT STANDING?". The design
  -- brief states it as `|A| = 1 and the sibling is inactive and holds a pot`, but that form
  -- contradicts its own second exclusion below: turning one of two accruing programmes off also
  -- leaves |A| = 1 with a sibling holding money, and that flip must NOT confiscate the paused
  -- pot. The movement form satisfies every case the brief enumerates, and it is exactly what
  -- app.programme_pot_switch_v312 expressed on loyalty_model (v312:1030-1039) — old identity vs
  -- new identity — generalised to the switchboard.
  --
  -- Enqueue iff, across this call, the SINGLE accruing programme changed from X to Y and X still
  -- holds money. Three cases deliberately do NOT enqueue:
  --   * adding a SECOND accruing programme  — |A| becomes 2; the points pot stays with points and
  --     stamps starts empty. Turning stamps on never moves anyone's points.
  --   * turning one of TWO off              — Y was ALREADY accruing before the flip, so identity
  --     did not move; the paused programme's pot is frozen, not confiscated, and turning it back
  --     on resumes the same pot.
  --   * both on                             — a split IS the intended state, and
  --     app.programme_balance_scope_v312 already reads programme_pot for it because it tests
  --     parity and negativity, not distinct tags.
  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points, v_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if (v_points and not v_stamps and v_stamps_before and not v_points_before)
     or (v_stamps and not v_points and v_points_before and not v_stamps_before) then
    select spine.id into v_to from public.business_programmes spine
     where spine.business_id = p_business
       and spine.kind = case when v_points then 'points' else 'stamps' end;
    select spine.id into v_from from public.business_programmes spine
     where spine.business_id = p_business
       and spine.kind = case when v_points then 'stamps' else 'points' end;
    -- Counted over the same set app.migrate_programme_pot_v312 processes: a non-zero ledger pot
    -- OR an open batch. A zero-pot switch enqueues nothing at all.
    if v_from is not null and v_to is not null and exists (
      select 1 from public.points_ledger ledger
       where ledger.business_id = p_business and ledger.programme_id = v_from
       group by ledger.client_id having sum(ledger.points) <> 0
      union all
      select 1 from public.points_batches batch
       where batch.business_id = p_business and batch.programme_id = v_from
         and batch.remaining > 0
    ) then
      v_migration := app.enqueue_programme_pot_migration_v312(p_business, v_from, v_to);
    end if;
  end if;

  v_result := jsonb_build_object(
    'business_id', p_business,
    'changed', v_changes,
    'pot_migration_id', v_migration,
    'programmes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', spine.kind,
               'active', spine.active,
               'running_since', spine.activated_at,
               'paused_since', spine.deactivated_at) order by spine.sort)
        from public.business_programmes spine
       where spine.business_id = p_business), '[]'::jsonb));

  update public.programme_switch_operations_v314
     set result = v_result
   where business_id = p_business and idempotency_key = p_idempotency_key;

  return v_result;
end
$$;

revoke all privileges on function public.set_programmes_v314(uuid,jsonb,uuid)
  from public, anon;
-- One role per statement, in the exact shape tests/security-hardening/v21-security-hardening.test.mjs
-- parses: a combined `to authenticated, service_role` grant is invisible to its allowlist scan and
-- the shipped SPA's call would read as an ungranted RPC.
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to authenticated;
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to service_role;

comment on function public.set_programmes_v314(uuid,jsonb,uuid) is
  'v314 W6i1: THE one intended writer of public.business_programmes. Takes a SET of switches in '
  'one call — per-kind calls would deadlock two owners against each other on the businesses row — '
  'gated by app.c45_owner_loyalty_write, locking the businesses row before the spine rows in kind '
  'order (V308 standing invariant 1). Reproduces the retired sync''s breadcrumb semantics exactly, '
  'writes nothing for a no-op flip, audits every real one as PROGRAMME_SWITCH_V314, and routes an '
  'accruing-identity change through app.enqueue_programme_pot_migration_v312 (V311/V312 standing '
  'invariant 2) — it never moves a point itself. Idempotent through '
  'public.programme_switch_operations_v314.';

-- ---------------------------------------------------------------------------
-- 3b. Retire trg_programme_pot_switch_v312 — IN THIS TRANSACTION.
--
--     It fires on `after update of loyalty_model on public.loyalty_programs`, and
--     publish_loyalty_config writes that column on EVERY publish (v55:711). Post-inversion
--     loyalty_model is a settings field, so a settings republish that happened to cross the
--     stamps boundary would enqueue a bogus transfer of a live points pot into the stamps
--     programme. That is a money bug, live, on the first republish after apply. The routing in
--     §2 replaces it and is keyed on the switch, which is now the only thing that can move
--     identity.
-- ---------------------------------------------------------------------------

drop trigger if exists trg_programme_pot_switch_v312 on public.loyalty_programs;

revoke all privileges on function app.programme_pot_switch_v312()
  from public, anon, authenticated;

comment on function app.programme_pot_switch_v312() is
  'v312 W5b model-switch router, RETIRED AT v314. loyalty_model is a SETTING after the inversion, '
  'so firing on it would move a live pot on an ordinary settings republish. '
  'public.set_programmes_v314 carries the routing now, keyed on the spine flip that actually '
  'changes identity. Kept installed and revoked so the rollback is `create trigger`.';

-- ---------------------------------------------------------------------------
-- 4. Freeze businesses.points_mode. SWALLOW + AUDIT (brief R4), not a raise.
-- ---------------------------------------------------------------------------

create or replace function app.points_mode_frozen_v314()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.points_mode is distinct from old.points_mode then
    -- The named escape, for migrations and for a deliberate platform repair. Transaction-local
    -- (set_config(..., true)); nothing in the product sets it.
    if coalesce(nullif(current_setting('app.points_mode_write_ok', true), ''), '') = 'v314' then
      return new;
    end if;
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (new.id, auth.uid(), 'POINTS_MODE_WRITE_SUPPRESSED_V314', 'businesses', new.id,
            jsonb_build_object('attempted', new.points_mode, 'kept', old.points_mode));
    new.points_mode := old.points_mode;
  end if;
  return new;
end
$$;

revoke all privileges on function app.points_mode_frozen_v314()
  from public, anon, authenticated;

comment on function app.points_mode_frozen_v314() is
  'v314 W6i1 tripwire on businesses.points_mode. SWALLOWS the write (pins the column to its old '
  'value) and records one audit_log row POINTS_MODE_WRITE_SUPPRESSED_V314 rather than raising — '
  'deliberate weakening of the design contract (brief R4). /app-*.js is CDN-pinned for about four '
  'hours, so the OLD bundle keeps PATCHing this column after every wizard publish for that long, '
  'and a raise would surface as a publish error to every owner in the window. Increment 9 '
  'upgrades it to a raise once the audit table proves zero writers remain. Escape GUC: '
  'set_config(''app.points_mode_write_ok'',''v314'',true).';

drop trigger if exists businesses_points_mode_frozen_v314 on public.businesses;
create trigger businesses_points_mode_frozen_v314
  before update of points_mode on public.businesses
  for each row
  execute function app.points_mode_frozen_v314();

comment on column public.businesses.points_mode is
  'FROZEN at v314 — historical record of the pre-switchboard choice. Read by nothing (the '
  'customer capability derives its points_mode key from the spine) and written by nothing (the '
  'v314 tripwire pins it and audits any attempt). The column survives so a firm''s pre-inversion '
  'choice remains recoverable and so the rollback has something to restore.';

-- ---------------------------------------------------------------------------
-- 5. Flip the consumers. SIX. Every one spliced against its live body with counted needles.
-- ---------------------------------------------------------------------------

do $v314_consumers$
declare
  v_def text;
  v_o integer;
  v_n integer;
  v_target record;
begin
  for v_target in
    select * from (values

      -- ---- CONSUMER 1. app.on_sale_recorded, the earn-loop gate (v311:515). -------------
      -- `lp` is the VERSION row from app.resolve_loyalty_branch_config; `lp.active` is the
      -- published version's flag, and it gated the WHOLE earn block. The loop already filters
      -- `spine.active and kind in ('points','stamps')`, so dropping this conjunct makes
      -- "at least one active accruing spine row" the gate — exactly the contract. WITHOUT THIS
      -- FLIP THE SWITCHBOARD VISIBLY DOES NOTHING: a firm whose switch says points-on but whose
      -- version row says active=false would still earn nothing.
      -- The needle carries the resolve call with it: a bare `if found then` already appears in
      -- the retention/referral block below, so an unanchored replacement would read as
      -- "already flipped" and silently skip.
      (1, 'app.on_sale_recorded()',
       $needle$app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found and lp.active then$needle$,
       $needle$app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found then$needle$),

      -- ---- CONSUMER 2. app.on_sale_recorded, the engine discriminator (v311:527). -------
      -- loyalty_program_versions.kind is a SECOND single-valued discriminator (v26:43). One
      -- version row carries both settings; only the two discriminators were exclusive. The
      -- points branch now requires a positive earn rate, mirroring the stamps branch's own
      -- `stamp_per_cents>0` guard, so a tiers-only firm with no rate silently earns nothing
      -- instead of writing a null-points row.
      (2, 'app.on_sale_recorded()',
       $needle$        elsif v_prog.kind='points' and lp.kind='points' then
          v_pts:=floor((new.amount_cents/100.0)*lp.earn_points_per_dollar);$needle$,
       $needle$        elsif v_prog.kind='points' then
          v_pts:=case when coalesce(lp.earn_points_per_dollar,0)>0 then floor((new.amount_cents/100.0)*lp.earn_points_per_dollar) else 0 end;$needle$),

      -- ---- CONSUMER 3. public.customer_portal_capabilities (v310:362-363, :380, :412). ---
      -- rewards and tiers derive from the SPINE. The points_mode KEY survives (v310:455,
      -- re-spliced at v312:513,520) because the client reads it; its VALUE becomes derived and
      -- is NEVER null — coalesce(points_mode,'tiers') at the old :412 would resurrect a ladder.
      -- W4a's cross-check invariant ("customer_visible for points/tiers equals the legacy
      -- capability") becomes TAUTOLOGICAL rather than broken: both sides now read one spine.
      (3, 'public.customer_portal_capabilities(text)',
       $needle$  v_points_mode text;$needle$,
       $needle$  v_points_mode text;
  v_points_active boolean;
  v_tiers_active boolean;$needle$),
      (4, 'public.customer_portal_capabilities(text)',
       $needle$  select business.points_mode
    into v_points_mode
    from public.businesses business
   where business.id=v_context.business_id;$needle$,
       $needle$  select coalesce(bool_or(spine.active) filter (where spine.kind='points'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='tiers'),false)
    into v_points_active, v_tiers_active
    from public.business_programmes spine
   where spine.business_id=v_context.business_id;
  v_points_mode := case
    when v_points_active and v_tiers_active then 'both'
    when v_tiers_active then 'tiers'
    else 'redeem'
  end;$needle$),
      (5, 'public.customer_portal_capabilities(text)',
       $needle$  v_rewards :=
    'loyalty'=any(v_context.enabled_modules)
    and coalesce(v_points_mode,'redeem') <> 'tiers'
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
         and ($needle$,
       $needle$  v_rewards :=
    'loyalty'=any(v_context.enabled_modules)
    and v_points_active
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and ($needle$),
      (6, 'public.customer_portal_capabilities(text)',
       $needle$  v_tiers :=
    'loyalty'=any(v_context.enabled_modules)
    and coalesce(v_points_mode,'tiers') in ('tiers','both')
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
    )
    and exists($needle$,
       $needle$  v_tiers :=
    'loyalty'=any(v_context.enabled_modules)
    and v_tiers_active
    and exists($needle$),

      -- ---- CONSUMER 4. public.customer_create_redemption_intent_v89, the v229 gate. ------
      -- v229:56 refused points_mode='tiers' BEFORE identity resolution, deliberately, so the
      -- rule held for every caller. That early property is preserved: the early gate becomes
      -- "this firm has no active accruing programme at all", and the precise per-reward
      -- question is asked at the hoist v313 installed, where the reward is known.
      (7, 'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
       $needle$  if exists(select 1 from public.businesses gate
             where gate.id=p_business and gate.points_mode='tiers') then
    raise exception 'points here count toward membership tiers and cannot be redeemed'
      using errcode='0A000';
  end if;$needle$,
       $needle$  if not exists(select 1 from public.business_programmes spine
             where spine.business_id=p_business and spine.active
               and spine.kind in ('points','stamps')) then
    raise exception 'this business is not running a programme you can redeem from'
      using errcode='0A000';
  end if;$needle$),
      (8, 'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
       $needle$  if v_intent_programme is null then
    raise exception 'redemption programme is not resolvable for this business' using errcode='XX001';
  end if;$needle$,
       $needle$  if v_intent_programme is null then
    raise exception 'redemption programme is not resolvable for this business' using errcode='XX001';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=v_intent_programme and spine.active) then
    raise exception 'this reward''s programme is not running right now' using errcode='0A000';
  end if;$needle$),
      -- CONSUMER 6, site 1 (same function): the catalogue model gate at v89:1021.
      (9, 'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
       $needle$    if v_program.loyalty_model not in ('points_tiers','stamps') then
      raise exception 'catalog redemption is unavailable' using errcode='22023';
    end if;$needle$,
       $needle$    if not exists(select 1 from public.business_programmes spine
                   where spine.business_id=p_business and spine.active
                     and spine.kind in ('points','stamps')) then
      raise exception 'catalog redemption is unavailable' using errcode='22023';
    end if;$needle$),

      -- ---- CONSUMER 5. app.redeem_reward_core, the model gate (v34:551). ----------------
      -- DECLARED BEHAVIOUR CHANGE, LIVE-VISIBLE: QA Test Cafe and QA Go-Live Cafe are
      -- loyalty_model='classic' and therefore cannot redeem a catalogue reward AT ALL today.
      -- After this flip, "points switched on" means catalogue redemption works for them. That is
      -- the intended semantics of the switchboard, and it is in the acceptance doc and the owner
      -- note rather than being discovered at a counter.
      --
      -- CONSUMER 5, SITE 1 — THE ROW LOOKUP ITSELF (v34:550). This is the OTHER half of the
      -- gate and it was missed in the first cut of this migration, with a measurable
      -- consequence: `where business_id=p_business and active limit 1` found no row at a firm
      -- whose published loyalty_programs row says active=false, so `not found` refused every
      -- catalogue redemption — while consumer 1 had just removed the identical `lp.active` test
      -- from the EARN gate. The same firm accrued and could not spend: liability with no exit.
      -- After this needle, pause is ONE truth in BOTH directions. The spine is what decides:
      -- app.on_sale_recorded loops over active accruing spine rows, and site 3 below refuses a
      -- reward whose own programme row is off. `lp` survives only as the "this business has a
      -- loyalty programme row at all" existence check it now is — the settings row, not a switch.
      (10, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  select * into lp from public.loyalty_programs where business_id=p_business and active limit 1;$needle$,
       $needle$  select * into lp from public.loyalty_programs where business_id=p_business limit 1;$needle$),
      -- CONSUMER 5, site 2. The model gate on the row that lookup returned.
      (11, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  if not found or lp.loyalty_model not in('points_tiers','stamps') then raise exception 'catalog redemption is inactive'; end if;$needle$,
       $needle$  if not found then raise exception 'catalog redemption is inactive'; end if;$needle$),
      -- CONSUMER 5, site 3. The reward's OWN programme has to be running.
      (12, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.business_id=p_business) then raise exception 'reward programme does not belong to this business' using errcode='42501'; end if;$needle$,
       $needle$  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.business_id=p_business) then raise exception 'reward programme does not belong to this business' using errcode='42501'; end if;
  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;$needle$),

      -- ---- CONSUMER 6, site 2. public.customer_get_business_actions_v89 (v89:876). -------
      -- The catalogue visibility list. Per-REWARD now, which is strictly better than the old
      -- per-business model test: a firm running points and stamps lists each gift under the
      -- programme that actually pays for it.
      (13, 'public.customer_get_business_actions_v89(uuid)',
       $needle$        and v_program.loyalty_model in ('points_tiers','stamps')$needle$,
       $needle$        and exists(select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.active)$needle$)
    ) targets(ord, signature, old_text, new_text)
    order by ord
  loop
    if to_regprocedure(v_target.signature) is null then
      raise exception 'v314: consumer target is missing: %', v_target.signature
        using errcode = '42883';
    end if;
    select pg_get_functiondef(to_regprocedure(v_target.signature)) into strict v_def;
    v_o := (length(v_def) - length(replace(v_def, v_target.old_text, '')))
           / length(v_target.old_text);
    v_n := (length(v_def) - length(replace(v_def, v_target.new_text, '')))
           / length(v_target.new_text);
    if v_n >= 1 then
      continue;                                       -- already flipped (re-run)
    end if;
    if v_o <> 1 then
      raise exception 'v314: consumer needle % in % matched old=% (expected exactly 1)',
        v_target.ord, v_target.signature, v_o using errcode = '23514';
    end if;
    execute replace(v_def, v_target.old_text, v_target.new_text);
  end loop;
end
$v314_consumers$;

-- ---- CONSUMER 6, site 3. The merchant scanners. -----------------------------------------
-- Two signatures carry the identical gate: public.merchant_scan_redemption_qr_v117(uuid,uuid,
-- text,uuid) is the LIVE settle path (app/app.js:1314, app/app-business.js:386) and
-- public.merchant_scan_redemption_qr_v89(uuid,text,uuid) is its fully-revoked predecessor, kept
-- installed. THE BRIEF NAMES ONLY THE v89 ONE — a repo-line citation (v89:1177) that is true of
-- both bodies. Flipping only the dead one would leave the reachable scanner refusing every
-- redemption at a firm whose loyalty_programs row is not `active`, which is the whole point of
-- the inversion. Both are flipped; the deviation is named here and in the acceptance doc.
--
-- Each body's whitespace differs, so each gets its own needle and its own count. `program.active`
-- leaves the row lookup (the row is a SETTINGS row now, and the terms comparison still needs it);
-- the spine answers "is a programme running" immediately after, preserving both the errcode and
-- the customer-readable message.
do $v314_scanners$
declare
  v_def text;
  v_o integer;
  v_target record;
  v_flipped integer := 0;
begin
  for v_target in
    select * from (values
      (1, 'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)',
       $needle$   where program.id=v_intent.quoted_program_id
     and program.business_id=p_business
     and program.active
   for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;$needle$,
       $needle$   where program.id=v_intent.quoted_program_id
     and program.business_id=p_business
   for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.business_id=p_business and spine.active
                   and spine.kind in ('points','stamps')) then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;$needle$),
      (2, 'public.merchant_scan_redemption_qr_v89(uuid,text,uuid)',
       $needle$  select * into v_program from public.loyalty_programs program
  where program.id=v_intent.quoted_program_id
    and program.business_id=p_business and program.active for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;$needle$,
       $needle$  select * into v_program from public.loyalty_programs program
  where program.id=v_intent.quoted_program_id
    and program.business_id=p_business for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.business_id=p_business and spine.active
                   and spine.kind in ('points','stamps')) then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;$needle$)
    ) targets(ord, signature, old_text, new_text)
    order by ord
  loop
    if to_regprocedure(v_target.signature) is null then
      -- v89's predecessor may legitimately be absent in a reduced environment; v117 may not.
      if v_target.ord = 1 then
        raise exception 'v314: the live merchant scanner % is missing', v_target.signature
          using errcode = '42883';
      end if;
      continue;
    end if;
    select pg_get_functiondef(to_regprocedure(v_target.signature)) into strict v_def;
    if position(v_target.new_text in v_def) > 0 then
      continue;
    end if;
    v_o := (length(v_def) - length(replace(v_def, v_target.old_text, '')))
           / length(v_target.old_text);
    if v_o <> 1 then
      raise exception 'v314: scanner needle % in % matched old=% (expected exactly 1)',
        v_target.ord, v_target.signature, v_o using errcode = '23514';
    end if;
    execute replace(v_def, v_target.old_text, v_target.new_text);
    v_flipped := v_flipped + 1;
  end loop;
  raise notice 'v314: % merchant scanner(s) flipped onto the spine', v_flipped;
end
$v314_scanners$;

-- ---------------------------------------------------------------------------
-- 6. The publish-time guard follows the switch.
--
--    v55:685 refuses a config whose ACTIVE stamps engine has no spend-per-stamp. Post-inversion
--    "active stamps engine" is the stamps SPINE ROW, not v_typed.active + loyalty_model='stamps'.
--    The points side stays lenient on purpose: an earn rate of 0 is a legal tiers-only
--    silent-accrual shape and the OWNER AMENDMENT protects it.
-- ---------------------------------------------------------------------------

do $v314_publish_guard$
declare
  v_def text;
  v_o integer;
  v_old text := $needle$  if v_typed.active and v_typed.loyalty_model='stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;$needle$;
  v_new text := $needle$  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;$needle$;
begin
  select pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into strict v_def;
  if position($guard$spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)$guard$ in v_def) > 0 then
    raise notice 'v314: the publish stamps guard already reads the spine';
    return;
  end if;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v314: publish stamps-guard needle matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  execute replace(v_def, v_old, v_new);
end
$v314_publish_guard$;

-- ---------------------------------------------------------------------------
-- 7. Retire the oracle. v307 keeps exactly ONE job.
--
--    app.business_programmes_v307's stated identity is "the legacy mirror" that must agree with
--    the spine row-for-row (v307:16-19). The inversion makes that unsatisfiable — a points+stamps
--    firm has no loyalty_model representation at all — so rewriting it in place would silently
--    change what every earlier wave's evidence was measured against. Instead: a new spine reader,
--    a re-comment, and a DETECTOR that reports the divergence instead of asserting it away.
-- ---------------------------------------------------------------------------

create or replace function app.business_programmes_active_v314(p_business uuid)
returns table(kind text, running boolean)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select programme.programme_kind,
         coalesce((select spine.active
                     from public.business_programmes spine
                    where spine.business_id = p_business
                      and spine.kind = programme.programme_kind), false)
    from (values (1,'points'),(2,'tiers'),(3,'stamps'),(4,'referral'))
           as programme(sort_order, programme_kind)
   order by programme.sort_order
$$;

revoke all privileges on function app.business_programmes_active_v314(uuid)
  from public, anon, authenticated;
grant execute on function app.business_programmes_active_v314(uuid) to service_role;

comment on function app.business_programmes_active_v314(uuid) is
  'v314 W6i1: the four programme flags read from the SPINE — the post-inversion successor to '
  'app.business_programmes_v307. Always four rows in the pinned order, all false for an unknown '
  'business. SECURITY DEFINER so a definer caller gets tenant truth rather than an RLS-shaped '
  'answer; browsers read public.business_programmes directly under their own SELECT policy.';

comment on function app.business_programmes_v307(uuid) is
  'v307 W1 read model — THE PRE-INVERSION ORACLE. It derives the four flags from the legacy '
  'columns and was the spine''s backfill source and mirror through W1-W5. As of v314 it is NO '
  'LONGER TRUTH: the spine is, and a firm running points and stamps together has no loyalty_model '
  'representation for this function to produce. It keeps exactly one live job — SEEDING a '
  'brand-new tenant''s four rows (app.seed_business_programmes_v314) and self-healing a firm that '
  'lacks them — plus its role as the reference every W1-W5 acceptance document was measured '
  'against. app.detect_spine_legacy_divergence_v314 reports where the two now differ; that report '
  'is expected to be non-empty and is never an assertion.';

create or replace function app.detect_spine_legacy_divergence_v314()
returns table (business_id uuid, business_name text, kind text,
               spine_active boolean, legacy_running boolean)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select business.id, business.name, model.kind, spine.active, model.running
    from public.businesses business
    cross join lateral app.business_programmes_v307(business.id) model
    join public.business_programmes spine
      on spine.business_id = business.id and spine.kind = model.kind
   where spine.active is distinct from model.running
   order by business.id, spine.kind
$$;

revoke all privileges on function app.detect_spine_legacy_divergence_v314()
  from public, anon, authenticated;
grant execute on function app.detect_spine_legacy_divergence_v314() to service_role;

comment on function app.detect_spine_legacy_divergence_v314() is
  'v314 W6i1: every (business, programme) where the SPINE and the pre-inversion legacy derivation '
  'disagree. Asserted EMPTY once, at apply, as proof that the inversion changed no firm''s '
  'behaviour on the day it landed. A REPORT AND NEVER AN ASSERTION thereafter: the first owner '
  'who switches a programme independently of loyalty_model makes it non-empty by design, and that '
  'is the product working.';

-- The authoring default follows authority (v313 §2 promised this replacement here). The resolver
-- is a lie from this commit onward, so the default stops asking it: a firm running exactly one
-- accruing programme prices new rewards in that one, and anything else falls back to points.
create or replace function app.reward_default_programme_v313(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(
    (select accruing.id
       from (select spine.id, count(*) over () as active_accruing
               from public.business_programmes spine
              where spine.business_id = p_business
                and spine.active
                and spine.kind in ('points','stamps')) accruing
      where accruing.active_accruing = 1),
    (select spine.id from public.business_programmes spine
      where spine.business_id = p_business and spine.kind = 'points')
  )
$$;

comment on function app.reward_default_programme_v313(uuid) is
  'v313 W6i1 authoring default, REBODIED BY v314. The programme a NEW reward belongs to when the '
  'author did not say: the business''s ONE active accruing programme when there is exactly one, '
  'and the points spine row otherwise (including when both run — a two-programme firm must choose, '
  'and increment 2''s authoring UI is where it does). No longer consults '
  'app.resolve_ledger_programme_v309, which the inversion turned into a statement about a '
  'settings column.';

-- ---------------------------------------------------------------------------
-- 8. loyalty_model and loyalty_programs.active are SETTINGS now. Say so on the columns.
-- ---------------------------------------------------------------------------

comment on column public.loyalty_programs.loyalty_model is
  'SETTINGS as of v314, not a switch. It still selects which engine SETTINGS a version carries '
  '(earn rate vs spend-per-stamp) and it is still single-valued and CHECK-constrained, but '
  '"is the stamps programme running?" is answered by public.business_programmes, not here. '
  'Recorded risk (W6 brief §7): loyalty_program_versions.kind and .loyalty_model remain '
  'single-valued under the v26 immutability guard, so a later increment that wants per-programme '
  'settings rows must plan for that guard.';

comment on column public.loyalty_programs.active is
  'SETTINGS as of v314: "this firm has a published loyalty configuration". It no longer decides '
  'which programmes run — public.business_programmes does, and it decides it COMPLETELY: a '
  'programme whose spine row is false neither accrues (app.on_sale_recorded) nor pays out '
  '(app.redeem_reward_core, which as of v314 does not test this column at all, in its row lookup '
  'or anywhere else) nor quotes (customer_create_redemption_intent_v89, '
  'customer_get_business_actions_v89). Pausing is therefore ONE flag with ONE meaning; setting '
  'this column false pauses nothing on its own, and every publish route in the browser applies '
  'the matching switch through public.set_programmes_v314. It is still read by the customer '
  'wallet/activity capabilities as "is loyalty configured at all", which is a deliberate residual '
  'named in the v314 acceptance doc for increment 2, not an oversight.';

-- ---------------------------------------------------------------------------
-- 9. Post-assertions. Fail closed.
-- ---------------------------------------------------------------------------

do $v314_post$
declare
  v_def text;
  v_count bigint;
  v_acl record;
begin
  -- 9.1 the four sync triggers are gone; the seeder and the tripwire are on.
  if exists (select 1 from pg_trigger
              where tgname in ('business_programmes_sync_businesses_v308',
                               'business_programmes_sync_loyalty_programs_v308',
                               'business_programmes_sync_loyalty_tiers_v308',
                               'business_programmes_sync_referral_programs_v308')
                and not tgisinternal) then
    raise exception 'v314: a v308 sync trigger survived the inversion' using errcode = '23514';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.businesses'::regclass
                    and tgname = 'business_programmes_seed_v314') then
    raise exception 'v314: THE SEEDER IS MISSING — every new tenant would have no spine rows'
      using errcode = '23514';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.businesses'::regclass
                    and tgname = 'businesses_points_mode_frozen_v314') then
    raise exception 'v314: the points_mode tripwire is missing' using errcode = '23514';
  end if;
  if exists (select 1 from pg_trigger
              where tgname = 'trg_programme_pot_switch_v312' and not tgisinternal) then
    raise exception 'v314: trg_programme_pot_switch_v312 survived; a settings republish can move '
      'a live pot' using errcode = '23514';
  end if;
  -- Nothing defers any more: V308 standing invariant 2 is retired, not merely unused.
  if exists (select 1 from pg_trigger
              where tgconstraint <> 0 and tgdeferrable
                and tgname like 'business_programmes%') then
    raise exception 'v314: a deferred spine trigger survives' using errcode = '23514';
  end if;

  -- 9.2 every consumer landed.
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position($needle$new.config_version_id);
    if found then$needle$ in v_def) = 0
     or position('lp.active' in v_def) <> 0
     or position($needle$elsif v_prog.kind='points' then$needle$ in v_def) = 0
     or position('lp.kind' in v_def) <> 0
     or position('on conflict (sale_id,programme_id)' in v_def) = 0
     or position('earn loop left ledger/batch parity broken' in v_def) = 0 then
    raise exception 'v314: the earn-loop flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  select pg_get_functiondef('public.customer_portal_capabilities(text)'::regprocedure)
    into strict v_def;
  if position('v_points_active' in v_def) = 0
     or position('v_tiers_active' in v_def) = 0
     or position($needle$'points_mode', v_points_mode$needle$ in v_def) = 0
     or position('programmes_contract' in v_def) = 0
     or position('app.programme_balance_scope_v312' in v_def) = 0
     or position($needle$coalesce(v_points_mode,'tiers')$needle$ in v_def) <> 0 then
    raise exception 'v314: the capabilities flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  select pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)
    into strict v_def;
  if position('lp.loyalty_model not in' in v_def) <> 0
     -- The row lookup must no longer carry `and active`: with consumer 1 having dropped the same
     -- test from the earn gate, leaving it here is a firm that accrues and cannot spend.
     or position('where business_id=p_business and active limit 1' in v_def) <> 0
     or position('where business_id=p_business limit 1' in v_def) = 0
     or position('spine.id=v_reward_programme and spine.active' in v_def) = 0
     or position('v_reward_programme:=v_version.programme_id' in v_def) = 0
     or position('v176_tier_gate_metric' in v_def) = 0 then
    raise exception 'v314: the redeem_reward_core flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  select pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('points_mode' in v_def) <> 0
     or position($needle$this reward''s programme is not running right now$needle$ in v_def) = 0
     or position('programme_id=v_intent_programme' in v_def) = 0 then
    raise exception 'v314: the intent flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  select pg_get_functiondef('public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)'::regprocedure)
    into strict v_def;
  if position('from public.business_programmes spine' in v_def) = 0
     or position('and program.active' in v_def) <> 0 then
    raise exception 'v314: the live merchant scanner flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  -- 9.3 nothing reads businesses.points_mode as a switch any more.
  for v_def in
    select n.nspname || '.' || p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public','app')
       and p.prosrc like '%points_mode%'
       and p.proname not in ('points_mode_frozen_v314')
  loop
    raise notice 'v314: % still mentions points_mode; verify it is presentation, not a switch',
      v_def;
  end loop;

  -- 9.4 the inversion changed nobody's behaviour TODAY. Asserted once, here, and never again.
  select count(*) into strict v_count from app.detect_spine_legacy_divergence_v314();
  if v_count <> 0 then
    raise exception 'v314: the spine already diverges from the legacy derivation in % row(s) — '
      'the inversion must land on an agreeing state', v_count using errcode = '23514';
  end if;

  -- 9.5 the money is still coherent.
  select count(*) into strict v_count from app.detect_programme_pot_split_v312();
  if v_count <> 0 then
    raise exception 'v314: the pot-split detector is not empty (% rows)', v_count
      using errcode = '23514';
  end if;

  -- 9.6 every business still owns exactly four spine rows.
  select count(*) into strict v_count from (
    select business.id from public.businesses business
      left join public.business_programmes spine on spine.business_id = business.id
     group by business.id
    having count(spine.id) <> 4 or count(distinct spine.kind) <> 4
  ) shape;
  if v_count <> 0 then
    raise exception 'v314: % business(es) do not own four spine rows', v_count
      using errcode = '23514';
  end if;

  -- 9.7 ACL floors. business_programmes stays SELECT-only for browsers; the new app functions
  --     stay browser-closed; the one new public RPC is authenticated-only (the owner gate inside
  --     it is what actually decides).
  if exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'business_programmes' and cmd <> 'SELECT'
  ) then
    raise exception 'v314: business_programmes gained a non-SELECT policy' using errcode = '42501';
  end if;
  if has_table_privilege('authenticated', 'public.business_programmes', 'INSERT')
     or has_table_privilege('authenticated', 'public.business_programmes', 'UPDATE')
     or has_table_privilege('authenticated', 'public.business_programmes', 'DELETE')
     or has_table_privilege('anon', 'public.business_programmes', 'SELECT') then
    raise exception 'v314: the business_programmes ACL floor is broken' using errcode = '42501';
  end if;
  if has_table_privilege('authenticated', 'public.programme_switch_operations_v314', 'INSERT')
     or has_table_privilege('anon', 'public.programme_switch_operations_v314', 'SELECT') then
    raise exception 'v314: the switch-receipt ACL floor is broken' using errcode = '42501';
  end if;
  for v_acl in
    select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname in ('seed_business_programmes_v314','points_mode_frozen_v314',
                         'business_programmes_active_v314','detect_spine_legacy_divergence_v314',
                         'sync_business_programmes_v308','programme_pot_switch_v312',
                         'reward_default_programme_v313')
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute'))
  loop
    raise exception 'v314: app.% is browser-callable', v_acl.proname using errcode = '42501';
  end loop;
  if has_function_privilege('anon', 'public.set_programmes_v314(uuid,jsonb,uuid)', 'execute') then
    raise exception 'v314: set_programmes_v314 is anon-callable' using errcode = '42501';
  end if;

  raise notice
    'v314 verified: four sync triggers dropped, seeder + tripwire + switch RPC installed, six '
    'consumers on the spine, pot routing owned by set_programmes_v314, both detectors empty, ACL '
    'floors held. tier_basis and every expiry knob deliberately untouched (OWNER AMENDMENT '
    '2026-08-14).';
end
$v314_post$;

commit;
