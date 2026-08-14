-- nestly_v320_gift_authoring_programme_and_stock
--
-- W6 WAVE 1, migration 3 of 3 (scratchpad w6design/01-ORCHESTRATOR-RULINGS.md "BUILD ORDER";
-- contract w6design/20-GIFTS.md, the AUTHORING half only — that contract labelled this half
-- "v319" and the enforcement half "v320"; the orchestrator's build order renumbers the authoring
-- half to v320 at slot 20260814000400 and reassigns ENFORCEMENT to WAVE 2's v324. Bind every
-- plan entry, manifest row and preflight mapping BY FULL MIGRATION NAME, never by semantic label:
-- v313-v318 are each already used, two of them twice.)
--
-- WHAT THIS IS. Authoring a gift stops being a guess about which programme it belongs to and
-- becomes an explicit choice, and the versioned reward row gains the ONE column a later increment
-- needs in order to cap a gift ("first 20 tote bags"). Nothing reads that column yet. That is
-- deliberate: it is what makes this migration provably behaviour-neutral.
--
-- WHY IT IS SAFE TO SAY "NO BEHAVIOUR CHANGE" OUT LOUD.
--   * total_stock is NULL on 100% of rows at apply and no function reads it. The reader, the cap
--     inside app.redeem_reward_core, the sold-out intent refusal and the owner's board are all
--     v324's, and this migration asserts by SNAPSHOT EQUALITY that it left every one of those
--     four bodies untouched (ruling R-G: read the md5 in step 0, compare against THAT value; a
--     transcribed literal would claim "nobody in the wave touched it", which no single migration
--     is entitled to claim).
--   * programme_id was ALREADY being filled on every one of these writes, by v313's BEFORE INSERT
--     default (app.reward_programme_default_v313). This migration replaces that default's GUESS
--     with the author's answer where the author gave one, and reproduces the guess exactly where
--     they did not: the coalesce chain's last arm IS app.reward_default_programme_v313. A payload
--     that never mentions programme_id therefore lands on the identical uuid it lands on today.
--
-- THE FOUR THINGS IT DOES.
--
-- 1. SA-3 — programme_id becomes an author-settable field on the authoring writers. Today
--    public.save_loyalty_reward_draft's whitelist holds ZERO occurrences of the string
--    programme_id (verified live 2026-08-14), so a client that sends it gets a hard 22023
--    'reward contains unsupported fields'. The client already documents this as the blocker
--    (app/app.js:24128). Four writers are spliced: save_loyalty_reward_draft (whitelist,
--    declarations, resolution, BOTH insert lists AND the ON CONFLICT DO UPDATE list),
--    app.clone_reward_versions_for_config (select list),
--    public.ensure_published_reward_in_draft_v138 (insert list), and public.publish_loyalty_config
--    (the reward projection — which already carries programme_id=rv.programme_id from v313 and
--    here gains only total_stock).
--
--    THE ON CONFLICT ENTRY IS NOT OPTIONAL. Without programme_id = excluded.programme_id an
--    existing draft row's programme could never be changed by an edit — the insert would conflict
--    and the DO UPDATE would silently preserve the old value. That is the failure mode the recon
--    recorded as live gap B, and suite cell C4 is its red-first proof.
--
-- 2. The accruing-kind guard, which STRENGTHENS v313. A gift tagged to the tiers or referral spine
--    row is permanently unclaimable: public.points_batches never holds a row for a non-accruing
--    programme, so app.redeem_reward_core's batch proof is always 0 and the claim raises
--    'insufficient proven points' forever. Making programme_id author-settable is what creates
--    that footgun, so the structural floor closes it in the same transaction — in BOTH doors, the
--    RPC (a clear message before any write) and app.reward_programme_tenant_guard_v313 (the floor
--    a direct write cannot get under). v313's cross-tenant refusal keeps its message and its
--    42501 byte-for-byte; exactly one refusal is added.
--
-- 3. total_stock, the column only. Config, versioned, cloned forward, projected at publish —
--    exactly the shape usage_limit already has. NULL means unlimited, which is why it is not
--    NOT NULL DEFAULT anything. No backfill is performed and none is possible: a cap is an owner
--    intention that has never been expressible in this product, so no tenant can be holding one,
--    and a migration that guessed would silently make a live gift finite.
--
-- 4. TWO DECLARED BUG FIXES found on the way. Both are no-ops in production today and both must
--    be in the evidence doc and the owner ledger rather than buried in a diff:
--
--    (a) app.clone_reward_versions_for_config reads the LIVE programme, not the source version's.
--        Today the clone omits programme_id entirely, so v313's default fills it from the live
--        public.loyalty_rewards row. Reassign a gift's programme in a draft, publish, then create
--        a new draft: the clone silently re-reads the live row. source.programme_id is strictly
--        more correct — in the normal case (based_on = the published version) the two are the
--        same uuid, and where they differ the SOURCE is the truth. Suite cell C6.
--        `active` keeps its deliberate coalesce(live.active, source.active). Untouched.
--
--    (b) public.ensure_published_reward_in_draft_v138 DROPS THE TIER GATE. Its INSERT lists 20
--        columns and omits min_tier_id / min_tier_threshold, so materialising a published reward
--        into a draft for editing silently opens a premium reward to everyone on the next publish.
--        Zero live rows carry a tier gate today (verified: 0 in loyalty_rewards, 0 in
--        loyalty_reward_versions), so this is a no-op in production and a real fix for the next
--        tenant. It rides here because it is the same INSERT statement; splitting it would mean
--        editing one body twice in one wave. Suite cell C7.
--
-- THE ONE HAZARD THE CONTRACT DID NOT SEE, AND HOW IT IS CLOSED. save_loyalty_reward_draft
-- decides whether to create the live public.loyalty_rewards row with `if not found then`, and
-- FOUND at that point still carries the result of the `select * into v_existing ... for update`
-- eight statements earlier — every statement in between is a plain assignment, which does not
-- touch FOUND. The contract's resolution block, as designed, opened with
-- `select spine.kind into v_programme_kind ...`, a SELECT INTO, which would have set FOUND true
-- and skipped the live-row insert for every brand-new gift, failing on the version row's FK a few
-- lines later. This migration removes the dependency instead of tiptoeing around it: FOUND is
-- captured into v_is_new the instant it is meaningful and the branch reads that. Suite cell C12
-- creates a gift from nothing and is the red-first proof.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH, asserted by snapshot equality in §7:
--   app.redeem_reward_core, public.customer_create_redemption_intent_v89,
--   public.customer_get_reward_catalog, public.customer_get_business_actions_v89
--   (v324's, per the build order), plus app.c45_base_actionable_wallet_card and
--   public.merchant_scan_redemption_qr_v117, recorded so a later reader knows it was a decision.
--
-- SNAPSHOT HASHES ARE NOT REFRESHED, ON PURPOSE. Adding a column changes what
-- app.refresh_loyalty_config_snapshot WOULD compute (it builds 'rewards' from
-- to_jsonb(rv) minus four keys, so total_stock is automatically inside the hash), but the stored
-- firm_config_versions.snapshot_hash does not move until something refreshes it. Refreshing here
-- would hand every owner holding an open draft a spurious 40001 'draft configuration changed;
-- reload before saving' on their next save. Leaving it alone is provably safe because both
-- save_loyalty_config_draft and ensure_published_reward_in_draft_v138 compare
-- p_expected_snapshot_hash against the STORED value BEFORE any write and refresh afterwards: the
-- first post-migration save passes and self-heals the hash. Postcondition 9 asserts that this
-- migration moved zero of them; suite cell C20 proves the self-heal.
--
-- Nothing here writes credit_ledger, points_ledger, points_batches, loyalty_redemptions, sales or
-- any other VALUE_TABLE. It adds one column to two CONFIG tables and re-states five bodies.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition. Same prelude, same reason, same order as v313: the live
-- media pipeline (public.business_publish_media_replacement_v95) holds storage.objects while
-- reading public.loyalty_rewards inside one transaction, and interleaving with it produced three
-- consecutive 40P01s on 2026-08-14. Take every contested relation up front, in one ordered LOCK.
-- storage.objects is conditional because verification rigs replay only app/public.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v320_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v320_prelock$;

lock table public.loyalty_rewards, public.loyalty_reward_versions
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- -0.5. The whole-catalogue digest probe, EXCLUDING the five bodies this migration is entitled to
-- re-state. It exists so that §0.c and §7.11 are provably the same expression rather than two
-- hand-copied ones (a typo in the second copy would fail the migration for a reason that is not
-- true). It is created inside this transaction and DROPPED before commit, so no other session can
-- ever observe it and the migration leaves behind exactly one new thing: the column.
-- ---------------------------------------------------------------------------

create or replace function app.v320_other_catalog_digest_probe()
returns text
language sql
stable
set search_path to 'pg_catalog','pg_temp'
as $$
  select md5(string_agg(p.oid::regprocedure::text || ':' || md5(p.prosrc), '|'
                        order by p.oid::regprocedure::text))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app')
     and (n.nspname, p.proname) not in (
           ('public','save_loyalty_reward_draft'),
           ('app','clone_reward_versions_for_config'),
           ('public','ensure_published_reward_in_draft_v138'),
           ('public','publish_loyalty_config'),
           ('app','reward_programme_tenant_guard_v313'))
$$;

-- ---------------------------------------------------------------------------
-- 0. Preconditions, and the snapshots every later claim is measured against.
--
--    Predecessor pins are HARDCODED and fail closed — that is what a predecessor pin is for.
--    NO-TOUCH pins are the opposite: read here, into a transaction-local GUC, and compared
--    against THAT value in §7 (ruling R-G).
-- ---------------------------------------------------------------------------

do $v320_pins$
declare
  v_applied boolean;
  v_half boolean;
  v_md5 text;
  v_bad bigint;
  v_divergent bigint;
begin
  if to_regclass('public.business_programmes') is null then
    raise exception 'v320: the v308 programme spine is absent' using errcode = '42P01';
  end if;

  -- Re-apply detection. Every step below is individually idempotent, so a second apply is a
  -- no-op rather than a refusal; but the predecessor pins can only be true the first time.
  v_applied := exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_rewards' and column_name = 'total_stock'
  ) and exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_reward_versions'
       and column_name = 'total_stock'
  );
  v_half := (exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_rewards' and column_name = 'total_stock'
  ) <> exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_reward_versions'
       and column_name = 'total_stock'
  ));
  if v_half then
    raise exception 'v320: total_stock exists on one reward table and not the other; refusing to '
                    'guess which half of an earlier run survived'
      using errcode = '23514';
  end if;
  perform set_config('app.v320_reapply', case when v_applied then 'yes' else 'no' end, true);

  -- v313's floor. Without NOT NULL programme_id and its four triggers this migration is
  -- meaningless: there would be nothing for an author to override.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name in ('loyalty_rewards','loyalty_reward_versions')
       and column_name = 'programme_id' and is_nullable = 'YES'
  ) then
    raise exception 'v320: loyalty reward programme_id is nullable; v313 is not applied'
      using errcode = '23514';
  end if;
  if (select count(*) from pg_trigger
       where not tgisinternal
         and tgname in ('trg_loyalty_rewards_programme_default_v313',
                        'trg_loyalty_reward_versions_programme_default_v313',
                        'trg_loyalty_rewards_programme_tenant_v313',
                        'trg_loyalty_reward_versions_programme_tenant_v313')) <> 4 then
    raise exception 'v320: a v313 programme trigger is missing' using errcode = '23514';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.businesses'::regclass
                    and tgname = 'business_programmes_seed_v314') then
    raise exception 'v320: the v314 spine seeder is missing' using errcode = '23514';
  end if;
  if to_regprocedure('app.reward_default_programme_v313(uuid)') is null then
    raise exception 'v320: app.reward_default_programme_v313 is absent; the resolution chain has '
                    'no last arm'
      using errcode = '23514';
  end if;

  -- The provenance assertion for the new accruing-kind guard: a refusal may only be added on top
  -- of zero pre-existing violators, or this migration would be making live rows unwritable.
  select count(*) into strict v_bad from (
    select 1 from public.loyalty_rewards r
      join public.business_programmes s on s.id = r.programme_id
     where s.kind not in ('points','stamps')
    union all
    select 1 from public.loyalty_reward_versions rv
      join public.business_programmes s on s.id = rv.programme_id
     where s.kind not in ('points','stamps')
  ) violators;
  if v_bad <> 0 then
    raise exception 'v320: % reward row(s) already name a non-accruing programme; the guard would '
                    'freeze them', v_bad
      using errcode = '23514';
  end if;

  -- Standing detectors. This migration touches no money row, so any movement in §7 is a defect it
  -- introduced.
  select count(*) into strict v_bad from app.detect_programme_pot_split_v312();
  if v_bad <> 0 then
    raise exception 'v320: the W5 pot-split detector is not empty (% rows)', v_bad
      using errcode = '23514';
  end if;
  select count(*) into strict v_bad from app.detect_double_earn_v309();
  if v_bad <> 0 then
    raise exception 'v320: the v309 double-earn detector is not empty (% rows)', v_bad
      using errcode = '23514';
  end if;

  -- RULING R-H: the spine/legacy divergence detector is a REPORT, never an assertion. It is
  -- non-empty in production right now because a real owner switched tiers on, which is the product
  -- working exactly as V313/V314 SI-5 predicted. A migration asserting it empty would refuse to
  -- apply for a correct reason.
  select count(*) into strict v_divergent from app.detect_spine_legacy_divergence_v314();
  raise notice 'v320: spine/legacy divergence detector reports % row(s) (REPORT ONLY, never '
               'asserted — see ruling R-H)', v_divergent;

  -- 0.a PREDECESSOR PINS. Hardcoded, read from production gadpooereceldfpfxsod on 2026-08-14,
  --     and skipped on a re-apply because by then they are the post-state.
  if current_setting('app.v320_reapply') = 'no' then
    select md5(p.prosrc) into strict v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
    if v_md5 <> '5a6bca2e79ea7380a772c6d7196a36b9' then
      raise exception 'v320: public.save_loyalty_reward_draft is not the expected predecessor '
                      'body (md5=%)', v_md5 using errcode = '23514';
    end if;

    select md5(p.prosrc) into strict v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'clone_reward_versions_for_config';
    if v_md5 <> 'ff309e27653a28b7b20760a4ac85d7cf' then
      raise exception 'v320: app.clone_reward_versions_for_config is not the expected predecessor '
                      'body (md5=%)', v_md5 using errcode = '23514';
    end if;

    select md5(p.prosrc) into strict v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'ensure_published_reward_in_draft_v138';
    if v_md5 <> '0bf4031e25171491541ee8c3e50141fa' then
      raise exception 'v320: public.ensure_published_reward_in_draft_v138 is not the expected '
                      'predecessor body (md5=%)', v_md5 using errcode = '23514';
    end if;

    select md5(p.prosrc) into strict v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
    if v_md5 <> '6bcc491a86d0f19a7284dc6deda83097' then
      raise exception 'v320: public.publish_loyalty_config is not the expected predecessor body '
                      '(md5=%)', v_md5 using errcode = '23514';
    end if;

    select md5(p.prosrc) into strict v_md5 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = 'reward_programme_tenant_guard_v313';
    if v_md5 <> 'deb9b5f7065732f2f9f8c7db2166da57' then
      raise exception 'v320: app.reward_programme_tenant_guard_v313 is not v313''s body (md5=%)',
        v_md5 using errcode = '23514';
    end if;
  else
    raise notice 'v320: re-apply detected (total_stock already present); predecessor pins skipped, '
                 'every step below is idempotent';
  end if;

  -- 0.b NO-TOUCH SNAPSHOTS (ruling R-G). Read HERE, compared against THIS value in §7. The first
  --     four are v324's targets and are the whole reason this migration can be called
  --     behaviour-neutral; the last two are recorded so a later reader knows they were considered.
  perform set_config('app.v320_notouch_core',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname = 'redeem_reward_core'), true);
  perform set_config('app.v320_notouch_intent',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'customer_create_redemption_intent_v89'), true);
  perform set_config('app.v320_notouch_catalog',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog'), true);
  perform set_config('app.v320_notouch_actions',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'customer_get_business_actions_v89'), true);
  perform set_config('app.v320_notouch_wallet',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname = 'c45_base_actionable_wallet_card'), true);
  perform set_config('app.v320_notouch_scan',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'merchant_scan_redemption_qr_v117'), true);

  -- 0.c The whole-catalog digest, EXCLUDING the five bodies this migration is entitled to
  --     re-state. Anything else that moves between here and §7 was moved by this migration and
  --     should not have been. Each of the five names has exactly one overload (asserted).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where (n.nspname, p.proname) in (
               ('public','save_loyalty_reward_draft'),
               ('app','clone_reward_versions_for_config'),
               ('public','ensure_published_reward_in_draft_v138'),
               ('public','publish_loyalty_config'),
               ('app','reward_programme_tenant_guard_v313'))) <> 5 then
    raise exception 'v320: expected exactly five splice targets, found a different number of '
                    'overloads' using errcode = '23514';
  end if;
  perform set_config('app.v320_catalog_digest', app.v320_other_catalog_digest_probe(), true);

  -- 0.d The two shapes §7 proves this migration did not disturb: every stored draft hash, and the
  --     row counts of both reward tables.
  perform set_config('app.v320_snapshot_digest',
    (select coalesce(md5(string_agg(f.id::text || ':' || coalesce(f.snapshot_hash,'~'), '|'
                                    order by f.id)), 'none')
       from public.firm_config_versions f), true);
  perform set_config('app.v320_rowcounts',
    (select (select count(*) from public.loyalty_rewards)::text || ':' ||
            (select count(*) from public.loyalty_reward_versions)::text), true);
  perform set_config('app.v320_acl_digest',
    (select md5(string_agg(x.sig, '|' order by x.sig)) from (
       select p.oid::regprocedure::text || ' ' || coalesce(p.proacl::text, 'NULL') as sig
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where (n.nspname, p.proname) in (
                ('public','save_loyalty_reward_draft'),
                ('app','clone_reward_versions_for_config'),
                ('public','ensure_published_reward_in_draft_v138'),
                ('public','publish_loyalty_config'),
                ('app','reward_programme_tenant_guard_v313'))) x), true);

  raise notice 'v320 preconditions met: v313 floor intact, zero non-accruing reward rows, '
               'detectors empty, no-touch snapshots recorded';
end
$v320_pins$;

-- ---------------------------------------------------------------------------
-- 1. The column. Config, versioned, nullable, positive-only. NULL = unlimited, the same shape
--    usage_limit already uses, because an unlimited gift must be representable.
-- ---------------------------------------------------------------------------

alter table public.loyalty_rewards         add column if not exists total_stock integer;
alter table public.loyalty_reward_versions add column if not exists total_stock integer;

do $v320_checks$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.loyalty_rewards'::regclass
                    and conname = 'loyalty_rewards_total_stock_check') then
    alter table public.loyalty_rewards
      add constraint loyalty_rewards_total_stock_check
      check (total_stock is null or total_stock > 0);
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.loyalty_reward_versions'::regclass
                    and conname = 'loyalty_reward_versions_total_stock_check') then
    alter table public.loyalty_reward_versions
      add constraint loyalty_reward_versions_total_stock_check
      check (total_stock is null or total_stock > 0);
  end if;
end
$v320_checks$;

comment on column public.loyalty_rewards.total_stock is
  'v320 D4. Optional TOTAL units across all customers, lifetime, for this reward_id. NULL = '
  'unlimited. This is CONFIG: authored on the draft version, cloned forward, projected here at '
  'publish. The COUNT is deliberately never stored — v324 derives it from public.loyalty_redemptions '
  'anti-joined against public.loyalty_redemption_reversals, keyed on reward_id so it survives every '
  'republish. Distinct from usage_limit, which is per customer. Nothing reads this column until '
  'v324; that is what makes v320 behaviour-neutral.';
comment on column public.loyalty_reward_versions.total_stock is
  'v320 D4. The AUTHORED cap on the immutable versioned row — the same column as '
  'loyalty_rewards.total_stock, one step earlier in the chain. NULL = unlimited.';

-- ---------------------------------------------------------------------------
-- 2. The accruing-kind guard. v313's cross-tenant refusal is preserved byte-for-byte in message
--    and errcode; exactly one refusal is added. Both triggers already fire
--    BEFORE INSERT OR UPDATE OF programme_id, business_id on both tables — no trigger changes,
--    only the body they share.
--
--    Trigger firing order is alphabetical within the same timing, so
--    ..._programme_default_v313 still runs before ..._programme_tenant_v313 and a defaulted
--    programme is still validated. app.reward_default_programme_v313 can only ever return a
--    points or stamps spine row, so the default path cannot trip the new refusal.
-- ---------------------------------------------------------------------------

create or replace function app.reward_programme_tenant_guard_v313()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_kind text;
begin
  if new.programme_id is not null then
    v_kind := (select spine.kind from public.business_programmes spine
                where spine.id = new.programme_id and spine.business_id = new.business_id);
    if v_kind is null then
      raise exception 'reward is tagged with another tenant''s programme'
        using errcode = '42501';
    end if;
    if v_kind not in ('points','stamps') then
      raise exception 'a gift may only belong to a programme customers earn into'
        using errcode = '22023';
    end if;
  end if;
  return new;
end
$$;

revoke all privileges on function app.reward_programme_tenant_guard_v313()
  from public, anon, authenticated;

comment on function app.reward_programme_tenant_guard_v313() is
  'v313 W6i1 + v320 W6 wave 1: the structural floor under a reward''s programme identity. Refuses '
  'a loyalty_rewards / loyalty_reward_versions row whose programme_id belongs to another business '
  '(42501, v313''s message unchanged), and — new in v320 — refuses one that names a NON-ACCRUING '
  'programme (tiers, referral) with 22023. points_batches never holds a row for a non-accruing '
  'programme, so such a gift is permanently unclaimable: redeem_reward_core''s batch proof is '
  'always 0 and the claim raises ''insufficient proven points'' forever. v320 makes programme_id '
  'author-settable, which is what creates that footgun, so the floor closes it in the same '
  'transaction.';

-- ---------------------------------------------------------------------------
-- 3. public.save_loyalty_reward_draft/4 — ten spliced edits, one re-state.
--
--    SPLICED, NEVER RE-STATED. This body carries a V176 "Stage A" min_tier_id/min_tier_threshold
--    patch that was applied by asserted string replacement against the LIVE definition and that
--    NO repo migration reproduces (v176b:51-53 records the fact). Re-stating it from any repo
--    source would silently delete the tier gate.
--
--    The resolution chain IS the contract: an explicit key wins, then the value the draft row
--    already holds, then the live published row, then v313's default. An edit that does not
--    mention programme_id NEVER moves it.
-- ---------------------------------------------------------------------------

do $v320_save$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
begin
  select pg_get_functiondef('public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb)'::regprocedure)
    into strict v_def;
  if position($probe$'programme_id','total_stock'$probe$ in v_def) > 0 then
    raise notice 'v320: save_loyalty_reward_draft already authors programme_id and total_stock';
    return;
  end if;

  -- S1. The whitelist. This one line is why the client cannot send a programme today.
  v_old := $n$'instructions','terms','image_ref','usage_limit','min_tier_id','min_tier_threshold'$n$;
  v_new := $n$'instructions','terms','image_ref','usage_limit','min_tier_id','min_tier_threshold',
       'programme_id','total_stock'$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S1 (whitelist) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S2. Declarations.
  v_old := $n$  v_min_tier_threshold integer;
$n$;
  v_new := $n$  v_min_tier_threshold integer;
  v_is_new boolean;
  v_programme_id uuid;
  v_programme_kind text;
  v_total_stock integer;
$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S2 (declarations) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S3. Capture FOUND the instant it is meaningful. See the header: the live-row branch below
  --     depends on FOUND surviving eight statements, and any future SELECT INTO in between would
  --     silently break the creation of every new gift. After S3 the branch reads a variable.
  v_old := $n$   where reward_id = v_reward_id and config_version_id = p_config_version for update;$n$;
  v_new := $n$   where reward_id = v_reward_id and config_version_id = p_config_version for update;
  v_is_new := not found;$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S3 (found capture) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S4. The live-row branch reads the captured value instead of FOUND.
  v_old := $n$  if not found then
    insert into public.loyalty_rewards ($n$;
  v_new := $n$  if v_is_new then
    insert into public.loyalty_rewards ($n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S4 (new-row branch) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S5. Resolution, immediately after the existing usage_limit resolution so the two per-gift
  --     limits are authored side by side. Both lookups are assignments, not SELECT INTO.
  v_old := $n$  v_limit := case when p_reward ? 'usage_limit' then nullif(p_reward->>'usage_limit','')::integer else v_existing.usage_limit end;$n$;
  v_new := $n$  v_limit := case when p_reward ? 'usage_limit' then nullif(p_reward->>'usage_limit','')::integer else v_existing.usage_limit end;
  v_programme_id := coalesce(
    nullif(btrim(coalesce(p_reward->>'programme_id','')),'')::uuid,
    v_existing.programme_id,
    (select live.programme_id from public.loyalty_rewards live
      where live.id = v_reward_id and live.business_id = v_header.business_id),
    app.reward_default_programme_v313(v_header.business_id));
  if v_programme_id is null then
    raise exception 'reward programme is not resolvable for this business' using errcode = '23514';
  end if;
  v_programme_kind := (select spine.kind from public.business_programmes spine
                        where spine.id = v_programme_id
                          and spine.business_id = v_header.business_id);
  if v_programme_kind is null then
    raise exception 'reward programme does not belong to this business' using errcode = '42501';
  end if;
  if v_programme_kind not in ('points','stamps') then
    raise exception 'a gift may only belong to a programme customers earn into' using errcode = '22023';
  end if;
  v_total_stock := case when p_reward ? 'total_stock'
    then nullif(btrim(coalesce(p_reward->>'total_stock','')),'')::integer
    else v_existing.total_stock end;
  if v_total_stock is not null and v_total_stock <= 0 then
    raise exception 'total available must be a positive whole number' using errcode = '22023';
  end if;$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S5 (resolution) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S6/S7. The live public.loyalty_rewards INSERT (new gifts only).
  v_old := $n$      image_ref, usage_limit, current_config_version_id
    ) values ($n$;
  v_new := $n$      image_ref, usage_limit, programme_id, total_stock, current_config_version_id
    ) values ($n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S6 (live insert columns) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $n$v_instructions, v_terms, v_image, v_limit,
      p_config_version
    );$n$;
  v_new := $n$v_instructions, v_terms, v_image, v_limit, v_programme_id, v_total_stock,
      p_config_version
    );$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S7 (live insert values) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S8/S9. The versioned row INSERT.
  v_old := $n$    terms, image_ref, usage_limit, min_tier_id, min_tier_threshold
  ) values ($n$;
  v_new := $n$    terms, image_ref, usage_limit, min_tier_id, min_tier_threshold, programme_id, total_stock
  ) values ($n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S8 (version insert columns) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $n$v_instructions, v_terms, v_image, v_limit, v_min_tier_id, v_min_tier_threshold
  ) on conflict (reward_id, config_version_id) do update set$n$;
  v_new := $n$v_instructions, v_terms, v_image, v_limit, v_min_tier_id, v_min_tier_threshold,
    v_programme_id, v_total_stock
  ) on conflict (reward_id, config_version_id) do update set$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S9 (version insert values) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- S10. THE ON CONFLICT ENTRY. Without it an existing draft gift's programme could never be
  --      changed by an edit: the conflict fires and the old value survives untouched.
  v_old := $n$    usage_limit = excluded.usage_limit
  returning id into v_version_id;$n$;
  v_new := $n$    usage_limit = excluded.usage_limit,
    programme_id = excluded.programme_id, total_stock = excluded.total_stock
  returning id into v_version_id;$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: save S10 (on conflict) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;

  select p.prosrc into strict v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
  if position($probe$'programme_id','total_stock'$probe$ in v_def) = 0
     or position('programme_id = excluded.programme_id' in v_def) = 0
     or position('total_stock = excluded.total_stock' in v_def) = 0
     or position('v_is_new := not found;' in v_def) = 0
     or position('if not found then' in v_def) <> 0
     or position('min_tier_id = excluded.min_tier_id' in v_def) = 0 then
    raise exception 'v320: save_loyalty_reward_draft re-splice did not land in its contracted shape'
      using errcode = '23514';
  end if;
end
$v320_save$;

comment on function public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb) is
  'v27 reward draft writer, v176 Stage A tier gate, v320 W6 SA-3 programme + total_stock. The '
  'gift''s programme is now an AUTHOR CHOICE resolved in this order: an explicit programme_id key, '
  'then the draft row''s current value, then the live published row, then '
  'app.reward_default_programme_v313 — so an edit that does not mention programme_id never moves '
  'it, and a payload that never mentions it lands exactly where v313''s default put it. A gift may '
  'only name an ACCRUING programme (points, stamps): points_batches never holds a row for tiers or '
  'referral, so such a gift would be permanently unclaimable. total_stock is the lifetime cap for '
  'ALL customers; usage_limit is the per-customer one. Nothing reads total_stock until v324.';

-- ---------------------------------------------------------------------------
-- 4. app.clone_reward_versions_for_config/0 — draft -> draft clone.
--
--    DECLARED BUG FIX (a). source.programme_id, not the live row's. See the header.
-- ---------------------------------------------------------------------------

do $v320_clone$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
begin
  select pg_get_functiondef('app.clone_reward_versions_for_config()'::regprocedure) into strict v_def;
  if position('source.programme_id' in v_def) > 0 then
    raise notice 'v320: clone_reward_versions_for_config already carries the source programme';
    return;
  end if;

  v_old := $n$    entitlement_expiry_days, instructions, terms, image_ref, usage_limit,
    min_tier_id, min_tier_threshold
  )$n$;
  v_new := $n$    entitlement_expiry_days, instructions, terms, image_ref, usage_limit,
    min_tier_id, min_tier_threshold, programme_id, total_stock
  )$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: clone C1 (insert columns) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $n$         source.usage_limit, source.min_tier_id, source.min_tier_threshold
    from public.loyalty_reward_versions source$n$;
  v_new := $n$         source.usage_limit, source.min_tier_id, source.min_tier_threshold,
         source.programme_id, source.total_stock
    from public.loyalty_reward_versions source$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: clone C2 (select list) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;

  select p.prosrc into strict v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'clone_reward_versions_for_config';
  if position('source.programme_id' in v_def) = 0
     or position('source.total_stock' in v_def) = 0
     or position('coalesce(live.active, source.active)' in v_def) = 0 then
    raise exception 'v320: clone_reward_versions_for_config re-splice did not land in its '
                    'contracted shape' using errcode = '23514';
  end if;
end
$v320_clone$;

comment on function app.clone_reward_versions_for_config() is
  'v197 draft-to-draft reward clone, v320 W6. Carries programme_id and total_stock forward from '
  'the SOURCE version rather than letting v313''s default re-read the LIVE loyalty_rewards row. '
  'DECLARED BUG FIX: reassign a gift''s programme in a draft, publish, then create a new draft — '
  'before v320 the clone silently re-read the live row. In the normal case (based_on = the '
  'published version) the two are the same uuid; where they differ the source is the truth. '
  '`active` keeps its deliberate coalesce(live.active, source.active) — a retire/unretire is a '
  'live action, not a versioned one.';

-- ---------------------------------------------------------------------------
-- 5. public.ensure_published_reward_in_draft_v138/3 — materialise a published reward for editing.
--
--    DECLARED BUG FIX (b). The live INSERT lists 20 columns and omits min_tier_id /
--    min_tier_threshold, so this function has been DROPPING THE TIER GATE on every materialise
--    since v138. Zero live rows carry a gate today, so the fix is a no-op in production. It rides
--    here because it is the same INSERT statement.
-- ---------------------------------------------------------------------------

do $v320_ensure$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
begin
  select pg_get_functiondef('public.ensure_published_reward_in_draft_v138(uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_source.programme_id' in v_def) > 0 then
    raise notice 'v320: ensure_published_reward_in_draft_v138 already carries the full row';
    return;
  end if;

  v_old := $n$    entitlement_expiry_days, instructions, terms, image_ref, usage_limit
  )
  values ($n$;
  v_new := $n$    entitlement_expiry_days, instructions, terms, image_ref, usage_limit,
    min_tier_id, min_tier_threshold, programme_id, total_stock
  )
  values ($n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: ensure E1 (insert columns) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $n$    v_source.image_ref, v_source.usage_limit
  )
  on conflict (reward_id, config_version_id) do nothing$n$;
  v_new := $n$    v_source.image_ref, v_source.usage_limit,
    v_source.min_tier_id, v_source.min_tier_threshold,
    v_source.programme_id, v_source.total_stock
  )
  on conflict (reward_id, config_version_id) do nothing$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: ensure E2 (insert values) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;

  select p.prosrc into strict v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ensure_published_reward_in_draft_v138';
  if position('v_source.programme_id' in v_def) = 0
     or position('v_source.total_stock' in v_def) = 0
     or position('v_source.min_tier_id' in v_def) = 0
     or position('v_source.min_tier_threshold' in v_def) = 0 then
    raise exception 'v320: ensure_published_reward_in_draft_v138 re-splice did not land in its '
                    'contracted shape' using errcode = '23514';
  end if;
end
$v320_ensure$;

comment on function public.ensure_published_reward_in_draft_v138(uuid,uuid,text) is
  'v138 owner-only configuration continuity writer, v320 W6. Copies a published reward into an '
  'older editable draft under row lock and optimistic snapshot hash. v320 adds the four columns '
  'the copy was silently dropping: programme_id and total_stock (new here) and — DECLARED BUG FIX '
  '— min_tier_id / min_tier_threshold, whose omission meant materialising a tier-gated reward for '
  'editing opened it to everyone on the next publish. Zero live rows carried a gate when this '
  'landed, so the fix is a no-op in production and a real fix for the next tenant.';

-- ---------------------------------------------------------------------------
-- 6. public.publish_loyalty_config/1 — the version -> live projection.
--
--    The REWARDS update only. It already carries programme_id=rv.programme_id (v313 shipped that)
--    and here gains total_stock. Verified disjoint from the PROGRAMS update that a later wave's
--    stamp kernel splices: that one is `update public.loyalty_programs set kind=...` and shares no
--    anchor with this needle.
-- ---------------------------------------------------------------------------

do $v320_publish$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
begin
  select pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into strict v_def;
  if position('total_stock=rv.total_stock' in v_def) > 0 then
    raise notice 'v320: publish_loyalty_config already projects total_stock';
    return;
  end if;
  if position('programme_id=rv.programme_id' in v_def) = 0 then
    raise exception 'v320: publish_loyalty_config has lost v313''s programme projection; refusing '
                    'to patch blind' using errcode = '23514';
  end if;

  v_old := $n$usage_limit=rv.usage_limit,min_tier_id=rv.min_tier_id,min_tier_threshold=rv.min_tier_threshold,current_config_version_id=p_version from public.loyalty_reward_versions rv$n$;
  v_new := $n$usage_limit=rv.usage_limit,total_stock=rv.total_stock,min_tier_id=rv.min_tier_id,min_tier_threshold=rv.min_tier_threshold,current_config_version_id=p_version from public.loyalty_reward_versions rv$n$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v320: publish P1 (reward projection) matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;

  select p.prosrc into strict v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
  if position('total_stock=rv.total_stock' in v_def) = 0
     or position('programme_id=rv.programme_id' in v_def) = 0 then
    raise exception 'v320: publish_loyalty_config re-splice did not land in its contracted shape'
      using errcode = '23514';
  end if;
end
$v320_publish$;

-- ---------------------------------------------------------------------------
-- 7. Postconditions. Every claim in the header is proved here or it is not claimed.
-- ---------------------------------------------------------------------------

do $v320_post$
declare
  v_src text;
  v_bad bigint;
  v_now text;
  v_divergent bigint;
begin
  -- 7.1 The column exists on both tables, integer, nullable, CHECKed, and NULL on every row.
  if (select count(*) from information_schema.columns
       where table_schema = 'public'
         and table_name in ('loyalty_rewards','loyalty_reward_versions')
         and column_name = 'total_stock' and data_type = 'integer' and is_nullable = 'YES') <> 2 then
    raise exception 'v320: total_stock is not a nullable integer on both reward tables'
      using errcode = '23514';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.loyalty_rewards'::regclass
                    and conname = 'loyalty_rewards_total_stock_check')
     or not exists (select 1 from pg_constraint
                     where conrelid = 'public.loyalty_reward_versions'::regclass
                       and conname = 'loyalty_reward_versions_total_stock_check') then
    raise exception 'v320: a total_stock CHECK is missing' using errcode = '23514';
  end if;
  if (select count(*) from public.loyalty_rewards where total_stock is not null)
     + (select count(*) from public.loyalty_reward_versions where total_stock is not null) <> 0 then
    raise exception 'v320: total_stock is set on a live row; this migration performs no backfill'
      using errcode = '23514';
  end if;

  -- 7.2 v313's floor is intact and no row moved.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name in ('loyalty_rewards','loyalty_reward_versions')
       and column_name = 'programme_id' and is_nullable = 'YES'
  ) then
    raise exception 'v320: programme_id became nullable' using errcode = '23514';
  end if;
  v_now := (select count(*) from public.loyalty_rewards)::text || ':' ||
           (select count(*) from public.loyalty_reward_versions)::text;
  if v_now <> current_setting('app.v320_rowcounts') then
    raise exception 'v320: reward row counts moved (% -> %); this migration writes no reward rows',
      current_setting('app.v320_rowcounts'), v_now using errcode = '23514';
  end if;

  -- 7.3 save_loyalty_reward_draft carries every contracted edit, exactly once each, and no longer
  --     depends on FOUND for the live-row branch.
  select p.prosrc into strict v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft';
  if (length(v_src) - length(replace(v_src, $q$'programme_id','total_stock'$q$, '')))
       / length($q$'programme_id','total_stock'$q$) <> 1
     or (length(v_src) - length(replace(v_src, 'programme_id = excluded.programme_id', '')))
       / length('programme_id = excluded.programme_id') <> 1
     or (length(v_src) - length(replace(v_src, 'total_stock = excluded.total_stock', '')))
       / length('total_stock = excluded.total_stock') <> 1
     or (length(v_src) - length(replace(v_src, 'v_is_new := not found;', '')))
       / length('v_is_new := not found;') <> 1
     or (length(v_src) - length(replace(v_src, 'if v_is_new then', '')))
       / length('if v_is_new then') <> 1
     or position('if not found then' in v_src) <> 0
     or position('app.reward_default_programme_v313(v_header.business_id)' in v_src) = 0
     or position('a gift may only belong to a programme customers earn into' in v_src) = 0 then
    raise exception 'v320: save_loyalty_reward_draft postcondition failed' using errcode = '23514';
  end if;

  -- 7.4 the clone carries the SOURCE row.
  select p.prosrc into strict v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'clone_reward_versions_for_config';
  if (length(v_src) - length(replace(v_src, 'source.programme_id', ''))) / length('source.programme_id') <> 1
     or (length(v_src) - length(replace(v_src, 'source.total_stock', ''))) / length('source.total_stock') <> 1
     or position('live.programme_id' in v_src) <> 0 then
    raise exception 'v320: clone_reward_versions_for_config postcondition failed'
      using errcode = '23514';
  end if;

  -- 7.5 the materialiser carries all four columns it was dropping.
  select p.prosrc into strict v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ensure_published_reward_in_draft_v138';
  if (length(v_src) - length(replace(v_src, 'v_source.programme_id',''))) / length('v_source.programme_id') <> 1
     or (length(v_src) - length(replace(v_src, 'v_source.total_stock',''))) / length('v_source.total_stock') <> 1
     or (length(v_src) - length(replace(v_src, 'v_source.min_tier_id',''))) / length('v_source.min_tier_id') <> 1
     or (length(v_src) - length(replace(v_src, 'v_source.min_tier_threshold',''))) / length('v_source.min_tier_threshold') <> 1 then
    raise exception 'v320: ensure_published_reward_in_draft_v138 postcondition failed'
      using errcode = '23514';
  end if;

  -- 7.6 the publish projection.
  select p.prosrc into strict v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
  if (length(v_src) - length(replace(v_src, 'total_stock=rv.total_stock',''))) / length('total_stock=rv.total_stock') <> 1
     or (length(v_src) - length(replace(v_src, 'programme_id=rv.programme_id',''))) / length('programme_id=rv.programme_id') <> 1 then
    raise exception 'v320: publish_loyalty_config postcondition failed' using errcode = '23514';
  end if;

  -- 7.7 the guard gained exactly one refusal, kept v313's, and freezes nothing.
  select p.prosrc into strict v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_programme_tenant_guard_v313';
  if md5(v_src) = 'deb9b5f7065732f2f9f8c7db2166da57'
     or position('reward is tagged with another tenant''s programme' in v_src) = 0
     or position('a gift may only belong to a programme customers earn into' in v_src) = 0 then
    raise exception 'v320: the accruing-kind guard did not land' using errcode = '23514';
  end if;
  select count(*) into strict v_bad from (
    select 1 from public.loyalty_rewards r
      join public.business_programmes s on s.id = r.programme_id
     where s.kind not in ('points','stamps')
    union all
    select 1 from public.loyalty_reward_versions rv
      join public.business_programmes s on s.id = rv.programme_id
     where s.kind not in ('points','stamps')
  ) violators;
  if v_bad <> 0 then
    raise exception 'v320: % reward row(s) resolve to a non-accruing programme', v_bad
      using errcode = '23514';
  end if;

  -- 7.8 every v313/v314 trigger is still attached, name for name, and the two standing guards on
  --     the versions table are still ENABLED. A migration that leaves the immutability guard off
  --     has turned every published config mutable.
  if (select count(*) from pg_trigger
       where not tgisinternal
         and tgname in ('trg_loyalty_rewards_programme_default_v313',
                        'trg_loyalty_reward_versions_programme_default_v313',
                        'trg_loyalty_rewards_programme_tenant_v313',
                        'trg_loyalty_reward_versions_programme_tenant_v313')) <> 4
     or not exists (select 1 from pg_trigger
                     where tgrelid = 'public.businesses'::regclass
                       and tgname = 'business_programmes_seed_v314') then
    raise exception 'v320: a programme trigger is missing' using errcode = '23514';
  end if;
  if (select count(*) from pg_trigger
       where tgrelid = 'public.loyalty_reward_versions'::regclass
         and tgname in ('trg_loyalty_reward_versions_immutable',
                        'trg_loyalty_reward_versions_snapshot')
         and tgenabled = 'O') <> 2 then
    raise exception 'v320: a standing loyalty_reward_versions trigger is missing or disabled'
      using errcode = '23514';
  end if;

  -- 7.9 NOT ONE STORED DRAFT HASH MOVED. This is the claim that makes "no owner sees a spurious
  --     40001 on their next save" true rather than hoped for.
  if (select coalesce(md5(string_agg(f.id::text || ':' || coalesce(f.snapshot_hash,'~'), '|'
                                     order by f.id)), 'none')
        from public.firm_config_versions f) <> current_setting('app.v320_snapshot_digest') then
    raise exception 'v320: a firm_config_versions.snapshot_hash changed; this migration refreshes '
                    'no snapshot' using errcode = '23514';
  end if;

  -- 7.10 RULING R-G. Snapshot equality against the values THIS transaction read in step 0 — never
  --      a transcribed literal. These four are v324's targets; the last two are recorded so a
  --      later reader knows leaving them alone was a decision.
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'redeem_reward_core')
     <> current_setting('app.v320_notouch_core') then
    raise exception 'v320: app.redeem_reward_core changed; the cap is v324''s, not this migration''s'
      using errcode = '23514';
  end if;
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'customer_create_redemption_intent_v89')
     <> current_setting('app.v320_notouch_intent') then
    raise exception 'v320: public.customer_create_redemption_intent_v89 changed; the sold-out '
                    'intent refusal is v324''s' using errcode = '23514';
  end if;
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog')
     <> current_setting('app.v320_notouch_catalog') then
    raise exception 'v320: public.customer_get_reward_catalog changed; the customer readers are '
                    'v324''s' using errcode = '23514';
  end if;
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'customer_get_business_actions_v89')
     <> current_setting('app.v320_notouch_actions') then
    raise exception 'v320: public.customer_get_business_actions_v89 changed; the customer readers '
                    'are v324''s' using errcode = '23514';
  end if;
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'c45_base_actionable_wallet_card')
     <> current_setting('app.v320_notouch_wallet') then
    raise exception 'v320: app.c45_base_actionable_wallet_card changed; its programme scoping is '
                    'ruling R-K''s work, not this migration''s' using errcode = '23514';
  end if;
  if (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'merchant_scan_redemption_qr_v117')
     <> current_setting('app.v320_notouch_scan') then
    raise exception 'v320: public.merchant_scan_redemption_qr_v117 changed; the QR path was to be '
                    'left alone' using errcode = '23514';
  end if;

  -- 7.11 Nothing else in the whole app/public catalogue moved, and the five keep their ACLs.
  --      create or replace preserves privileges; this proves it rather than assuming it.
  if app.v320_other_catalog_digest_probe() <> current_setting('app.v320_catalog_digest') then
    raise exception 'v320: a function outside the five re-stated bodies changed'
      using errcode = '23514';
  end if;
  if (select md5(string_agg(x.sig, '|' order by x.sig)) from (
        select p.oid::regprocedure::text || ' ' || coalesce(p.proacl::text, 'NULL') as sig
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where (n.nspname, p.proname) in (
                 ('public','save_loyalty_reward_draft'),
                 ('app','clone_reward_versions_for_config'),
                 ('public','ensure_published_reward_in_draft_v138'),
                 ('public','publish_loyalty_config'),
                 ('app','reward_programme_tenant_guard_v313'))) x)
     <> current_setting('app.v320_acl_digest') then
    raise exception 'v320: an ACL on a re-stated function changed' using errcode = '23514';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.proname = 'reward_programme_tenant_guard_v313'
                and (has_function_privilege('anon', p.oid, 'execute')
                     or has_function_privilege('authenticated', p.oid, 'execute'))) then
    raise exception 'v320: the tenant guard is browser-callable' using errcode = '42501';
  end if;

  -- 7.12 detectors, and the report that is never an assertion.
  select count(*) into strict v_bad from app.detect_programme_pot_split_v312();
  if v_bad <> 0 then
    raise exception 'v320: the pot-split detector is not empty (% rows)', v_bad
      using errcode = '23514';
  end if;
  select count(*) into strict v_bad from app.detect_double_earn_v309();
  if v_bad <> 0 then
    raise exception 'v320: the double-earn detector is not empty (% rows)', v_bad
      using errcode = '23514';
  end if;
  select count(*) into strict v_divergent from app.detect_spine_legacy_divergence_v314();

  -- 7.13 The post-apply md5s. These are v324's pins and belong in the evidence doc verbatim.
  raise notice 'v320 POST-APPLY PINS: save_loyalty_reward_draft=% clone_reward_versions_for_config=% '
               'ensure_published_reward_in_draft_v138=% publish_loyalty_config=% '
               'reward_programme_tenant_guard_v313=%',
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'save_loyalty_reward_draft'),
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname = 'clone_reward_versions_for_config'),
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'ensure_published_reward_in_draft_v138'),
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'publish_loyalty_config'),
    (select md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app' and p.proname = 'reward_programme_tenant_guard_v313');
  raise notice 'v320 UNCHANGED (snapshot equality, ruling R-G): redeem_reward_core=% intent_v89=% '
               'reward_catalog=% business_actions=% wallet_card=% scan_v117=%',
    current_setting('app.v320_notouch_core'), current_setting('app.v320_notouch_intent'),
    current_setting('app.v320_notouch_catalog'), current_setting('app.v320_notouch_actions'),
    current_setting('app.v320_notouch_wallet'), current_setting('app.v320_notouch_scan');
  raise notice 'v320 verified: total_stock added (NULL on 100%% of rows, read by nothing), '
               'programme_id is an author choice on all four writers, the accruing-kind guard is '
               'the floor, two declared bug fixes landed, zero snapshot hashes moved, four v324 '
               'targets byte-identical, divergence detector reports % row(s)', v_divergent;
end
$v320_post$;

-- The probe used by §0.c and §7.11 exists only to make those two expressions provably identical
-- and is dropped before commit, so this migration leaves no new object behind but the column.
drop function if exists app.v320_other_catalog_digest_probe();

commit;
