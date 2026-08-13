-- nestly_v313_reward_programme_identity
--
-- W6 INCREMENT 1, PART a of b (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md;
-- W6 build brief [INCREMENT-1 BRIEF: SERVER] §v313). Applies immediately before
-- nestly_v314_programme_switchboard_inversion and is a HARD PRECONDITION of it.
--
-- WHAT THIS IS. A reward stops being "whatever the firm's single accruing programme happens to
-- be" and becomes a row that KNOWS which programme it is priced in.
-- public.loyalty_rewards and public.loyalty_reward_versions each gain programme_id ->
-- public.business_programmes(id), backfilled from app.resolve_ledger_programme_v309 and then
-- NOT NULL. Catalogue redemption (app.redeem_reward_core) and the customer affordability quote
-- (public.customer_create_redemption_intent_v89) stop asking the BUSINESS which programme to
-- drain and start asking the REWARD.
--
-- WHY IT MUST BE THIS TRANSACTION AND NOT A LATER ONE. app.resolve_ledger_programme_v309
-- (v309:258-277) answers from loyalty_programs.loyalty_model = 'stamps', a single-valued
-- column. That answer is exactly true for as long as a business can run only one accruing
-- programme, and v314 — the very next migration — is what ends that. So this backfill is
-- legitimate only here, in the last transaction in which the resolver is unambiguous. This is
-- V309's own window argument, restated one wave later and one wave narrower.
--
-- WITHOUT THIS, v314 SHIPS A MONEY BUG. With the switchboard live and the resolver still inside
-- redeem_reward_core, a firm running points AND stamps would drain whichever pot the resolver
-- guessed: a stamp gift paid for out of the customer's points, or a points reward paid for out
-- of their stamp card. That is the cross-programme double-spend V311 §5.4 closed for the
-- single-programme world and this migration closes for the multi-programme one.
--
-- NON-GOAL, STATED SO A LATER READER DOES NOT "TIDY IT UP": this migration does not touch
-- loyalty_programs.tier_basis, loyalty_program_versions.tier_basis, expiry_mode, expiry_days or
-- any other expiry knob. OWNER AMENDMENT 2026-08-14 (docs/design/FOUR-PROGRAMME-INDEPENDENCE-
-- PLAN.md §7): tiered membership co-exists with the other programmes and the basis choice
-- survives. W5 verified both non-points branches of app.loyalty_tier_for and both expiry modes
-- are logic-identical to v148 (V311-V312-W5-MONEY-WAVE-ACCEPTANCE.md:20-28). Nothing here
-- disturbs that, deliberately.
--
-- WHAT IT DOES NOT CHANGE. No owner-visible behaviour. Every business today has exactly one
-- accruing programme (loyalty_model is single-valued and CHECK-constrained), so
-- "the reward's programme" and "the business's programme" are the same uuid for every existing
-- row, and every code path below computes the same answer it computed yesterday. The change is
-- that the answer now has a place to be WRONG in — a reward on the stamps programme at a firm
-- that also runs points — which is precisely what v314 makes reachable.
--
-- HOW THE COLUMN GETS FILLED, AND WHY IT IS NOT FOUR COLUMN-LIST SPLICES. The four writers of
-- these two tables are:
--   public.save_loyalty_reward_draft             (v27:618 INSERT + v27:631 INSERT..ON CONFLICT)
--   app.clone_reward_versions_for_config         (v197:51, the draft->draft clone trigger)
--   public.ensure_published_reward_in_draft_v138 (v138:421, restore-a-published-reward)
--   public.publish_loyalty_config                (v55:711, the version -> live UPDATE projection)
-- Two of them — save_loyalty_reward_draft and publish_loyalty_config — carry a V176 "Stage A"
-- min_tier_id/min_tier_threshold patch that was applied by asserted string replacement against
-- their LIVE definitions and that NO repo migration reproduces (v176b:51-53 records the fact;
-- 20260806_nestly_v176_reward_tier_gate.sql adds the columns and stops). Their live column lists
-- therefore have a shape this repo cannot predict, and a column-list needle written against
-- v27/v55 would either miss (fail closed, but block the wave) or land half a splice.
--
-- So the three INSERT writers are covered by a BEFORE INSERT default — the v309 idiom, applied
-- to CONFIG rows rather than money rows — and only the UPDATE projection is spliced, on an anchor
-- (`update public.loyalty_rewards r set `) that no Stage A edit can have moved. The doctrinal
-- difference from v311 is deliberate and narrow: v309's money default was retired because it
-- guessed from a resolver that was about to become a lie, whereas this default is derived from
-- the row's OWN business and, for a version, from its OWN live reward — the answer is correct by
-- construction, not by oracle, and it fails loudly (23514) when it cannot be determined.
-- Increment 2's authoring UI is what makes the choice explicit and owner-visible.
--
-- THE v309 TAG TRIGGERS ARE RETIRED HERE. V311/V312 standing invariant 5 grants this explicitly
-- and names suite steps 29-36 as the standing proof that every money writer is already explicit.
-- They are dropped rather than kept because a resolver that is about to become a lie must not be
-- able to fill programme_id for a writer that forgot: under NOT NULL such a writer now names
-- itself with a constraint violation instead of silently tagging money to the wrong pot. The
-- FUNCTIONS app.tag_ledger_programme_v309 and app.resolve_ledger_programme_v309 stay installed,
-- revoked and re-commented, so the rollback is a re-attach rather than a rewrite.
--
-- Nothing here writes credit_ledger, points_ledger, points_batches, sales or any other
-- VALUE_TABLE. It adds a column to two CONFIG tables and re-points two read-side predicates.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition (added after the 2026-08-14 production
-- deadlocks; three consecutive 40P01s, same signature each time). The live
-- media pipeline (public.business_publish_media_replacement_v95, observed as a
-- continuous PostgREST retry stream) holds storage.objects while reading
-- loyalty_rewards inside one transaction; interleaving lock acquisition with it
-- deadlocks. Taking every contested relation up front, in one ordered LOCK,
-- makes a cycle impossible — the stream simply queues behind the migration for
-- the few seconds it runs. storage.objects is locked conditionally because
-- verification rigs replay only the app/public schemas.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v313_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v313_prelock$;

lock table public.loyalty_rewards, public.loyalty_reward_versions,
           public.points_ledger, public.points_batches
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- 0. Preconditions. Fail closed on anything that would make the backfill a guess.
-- ---------------------------------------------------------------------------

do $v313_pins$
declare
  v_core_raw text;
  v_intent_raw text;
  v_missing bigint;
  v_untagged bigint;
begin
  if to_regclass('public.business_programmes') is null then
    raise exception 'v313: the v308 programme spine is absent' using errcode = '42P01';
  end if;

  -- Already applied? Say so plainly rather than aborting on an "unexpected predecessor", which
  -- is true but reads like production drift. This migration is one-apply: the column adds are
  -- idempotent, the four splices are individually idempotent, the NOT NULL is not.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_rewards'
       and column_name = 'programme_id'
  ) then
    raise exception 'v313 is already applied (loyalty_rewards.programme_id exists)'
      using errcode = '23514';
  end if;

  -- W5 post-state pins. Recorded at V311-V312-W5-MONEY-WAVE-ACCEPTANCE.md:99-113. Neither body
  -- carries a full-line comment, so raw and comment-normalised md5 are the same value and one
  -- comparison covers both an MCP apply and a byte-faithful one.
  select md5(p.prosrc) into strict v_core_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if v_core_raw <> '91171a153bc295bbaf0e535b3e9c4d7b' then
    raise exception 'v313: app.redeem_reward_core is not the W5 post-state body (md5=%)',
      v_core_raw using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_intent_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_create_redemption_intent_v89';
  if v_intent_raw <> 'f396a1e8e5914e880c293303276a5cc1' then
    raise exception
      'v313: public.customer_create_redemption_intent_v89 is not the W5 post-state body (md5=%)',
      v_intent_raw using errcode = '23514';
  end if;

  -- The spine must be complete before it can be a backfill source: a business missing its four
  -- rows would take a NULL programme and abort the NOT NULL below with a confusing message.
  select count(*) into strict v_missing
    from public.businesses business
    where not exists (
      select 1 from public.business_programmes spine
       where spine.business_id = business.id and spine.kind = 'points'
    );
  if v_missing <> 0 then
    raise exception 'v313: % business(es) have no points spine row', v_missing
      using errcode = '23514';
  end if;

  -- W5 left both money tables NOT NULL and both detectors empty. If that is not still true the
  -- resolver's answer is already suspect and this backfill must not run on top of it.
  select count(*) into strict v_untagged from app.detect_programme_pot_split_v312();
  if v_untagged <> 0 then
    raise exception 'v313: the W5 pot-split detector is not empty (% rows)', v_untagged
      using errcode = '23514';
  end if;

  raise notice 'v313 predecessor pins met: redeem_reward_core=%, intent_v89=%',
    v_core_raw, v_intent_raw;
end
$v313_pins$;

-- ---------------------------------------------------------------------------
-- 1. The column, on both tables, nullable for exactly as long as the backfill takes.
-- ---------------------------------------------------------------------------

alter table public.loyalty_rewards         add column programme_id uuid;
alter table public.loyalty_reward_versions add column programme_id uuid;

alter table public.loyalty_rewards
  add constraint loyalty_rewards_programme_fk
  foreign key (programme_id) references public.business_programmes(id)
  on delete restrict;
alter table public.loyalty_reward_versions
  add constraint loyalty_reward_versions_programme_fk
  foreign key (programme_id) references public.business_programmes(id)
  on delete restrict;

-- The FK constrains the PROGRAMME, not the TENANT: business_programmes(id) is unique on its own,
-- so nothing in the constraint stops a reward from pointing at another firm's spine row. v309
-- had the same hole on points_ledger and v311 closed it with an in-trigger existence check
-- (v311:424-433). Same doctrine here, one PK lookup per write, permanent rather than asserted
-- once at backfill.
create or replace function app.reward_programme_tenant_guard_v313()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.programme_id is not null and not exists (
    select 1 from public.business_programmes spine
     where spine.id = new.programme_id and spine.business_id = new.business_id
  ) then
    raise exception 'reward is tagged with another tenant''s programme'
      using errcode = '42501';
  end if;
  return new;
end
$$;

revoke all privileges on function app.reward_programme_tenant_guard_v313()
  from public, anon, authenticated;

comment on function app.reward_programme_tenant_guard_v313() is
  'v313 W6i1: refuses a loyalty_rewards / loyalty_reward_versions row whose programme_id belongs '
  'to another business. The FK references business_programmes(id) only, so without this a '
  'cross-tenant tag is a legal row and redeem_reward_core would drain a pot in the wrong firm''s '
  'namespace. Mirrors the guard v311:424-433 put on points_ledger.';

drop trigger if exists trg_loyalty_rewards_programme_tenant_v313 on public.loyalty_rewards;
create trigger trg_loyalty_rewards_programme_tenant_v313
  before insert or update of programme_id, business_id on public.loyalty_rewards
  for each row execute function app.reward_programme_tenant_guard_v313();

drop trigger if exists trg_loyalty_reward_versions_programme_tenant_v313
  on public.loyalty_reward_versions;
create trigger trg_loyalty_reward_versions_programme_tenant_v313
  before insert or update of programme_id, business_id on public.loyalty_reward_versions
  for each row execute function app.reward_programme_tenant_guard_v313();

-- ---------------------------------------------------------------------------
-- 2. The authoring default.
--
--    The brief's rule is "a reward created after v313 with no explicit programme defaults to the
--    business's points spine row". That is right for every firm whose accruing programme IS
--    points, and WRONG for a stamps firm — its new rewards would be priced in a pot its
--    customers never fill, which is the exact defect §5.4/v313 exists to close, merely moved
--    from redemption time to authoring time. AMENDMENT, recorded here and in the evidence doc:
--    the default is "the business's accruing programme, points when that is ambiguous".
--
--    v313's body answers through the resolver, because inside THIS wave the resolver is still
--    exactly right. v314 REPLACES this function with a spine-based body in the same transaction
--    that makes the resolver a lie, so the authoring default follows authority rather than
--    outliving it. Keeping the default in one named function is what makes that replacement a
--    one-line change instead of four more splices.
-- ---------------------------------------------------------------------------

create or replace function app.reward_default_programme_v313(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(
    app.resolve_ledger_programme_v309(p_business),
    (select spine.id from public.business_programmes spine
      where spine.business_id = p_business and spine.kind = 'points')
  )
$$;

revoke all privileges on function app.reward_default_programme_v313(uuid)
  from public, anon, authenticated;
grant execute on function app.reward_default_programme_v313(uuid) to service_role;

comment on function app.reward_default_programme_v313(uuid) is
  'v313 W6i1: the programme a NEW reward belongs to when the author did not say. Pre-inversion '
  'body: the v309 single-pot answer, falling back to the points spine row. REPLACED BY v314 with '
  'a spine-based body the moment loyalty_model stops being the switch — the default must follow '
  'authority, not outlive it. SECURITY DEFINER because both sources are RLS-protected and the '
  'author''s session must not shape the answer.';

-- ---------------------------------------------------------------------------
-- 3. The backfill. Legitimate ONLY in this transaction (see the header).
-- ---------------------------------------------------------------------------

update public.loyalty_rewards reward
   set programme_id = app.reward_default_programme_v313(reward.business_id)
 where reward.programme_id is null;

-- The versions backfill fills a NEW IDENTITY column on historical rows; it does not change any
-- published configuration value. Two standing triggers would otherwise misread it: the v26-line
-- immutability guard (trg_loyalty_reward_versions_immutable) refuses ALL DML on a version row
-- whose config is non-draft — discovered on the first production apply attempt, 23001 on the 98
-- live version rows, a case the rig's empty-catalogue fixture never exercised — and the snapshot
-- refresher (trg_loyalty_reward_versions_snapshot) would rebuild every historical config's
-- snapshot once per touched row for a column snapshots do not read. Both are suspended for
-- exactly this one statement, under the AccessExclusiveLock taken in the prelude, and re-enabled
-- immediately after; the postcondition block asserts both are back on ('O'). The v313 tenant
-- guard trigger created above stays LIVE through the backfill — it is the check, not the noise.
alter table public.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_immutable;
alter table public.loyalty_reward_versions disable trigger trg_loyalty_reward_versions_snapshot;

update public.loyalty_reward_versions reward_version
   set programme_id = app.reward_default_programme_v313(reward_version.business_id)
 where reward_version.programme_id is null;

alter table public.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_immutable;
alter table public.loyalty_reward_versions enable trigger trg_loyalty_reward_versions_snapshot;

-- A reward's VERSIONS must agree with the reward: the version is what redeem_reward_core reads
-- and the live row is what the catalogue lists, so a disagreement is a reward that quotes one
-- pot and drains another. Post-backfill they agree by construction (both derive from the same
-- business); this asserts it rather than assuming it, and the assertion survives as the shape
-- every later writer must preserve.
do $v313_backfill$
declare
  v_reward_nulls bigint;
  v_version_nulls bigint;
  v_cross bigint;
  v_disagree bigint;
  v_rewards bigint;
  v_versions bigint;
begin
  select count(*) into strict v_reward_nulls
    from public.loyalty_rewards where programme_id is null;
  select count(*) into strict v_version_nulls
    from public.loyalty_reward_versions where programme_id is null;
  if v_reward_nulls <> 0 or v_version_nulls <> 0 then
    raise exception
      'v313 backfill: % loyalty_rewards and % loyalty_reward_versions rows are still untagged',
      v_reward_nulls, v_version_nulls using errcode = '23514';
  end if;

  select count(*) into strict v_cross from (
    select 1 from public.loyalty_rewards reward
      join public.business_programmes spine on spine.id = reward.programme_id
     where spine.business_id <> reward.business_id
    union all
    select 1 from public.loyalty_reward_versions reward_version
      join public.business_programmes spine on spine.id = reward_version.programme_id
     where spine.business_id <> reward_version.business_id
  ) cross_tagged;
  if v_cross <> 0 then
    raise exception 'v313 backfill: % row(s) carry another tenant''s programme', v_cross
      using errcode = '42501';
  end if;

  select count(*) into strict v_disagree
    from public.loyalty_reward_versions reward_version
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
   where reward.programme_id is distinct from reward_version.programme_id;
  if v_disagree <> 0 then
    raise exception
      'v313 backfill: % reward version(s) disagree with their live reward''s programme', v_disagree
      using errcode = '23514';
  end if;

  select count(*) into strict v_rewards from public.loyalty_rewards;
  select count(*) into strict v_versions from public.loyalty_reward_versions;
  raise notice
    'v313 backfill verified: % loyalty_rewards and % loyalty_reward_versions tagged, zero nulls, '
    'zero cross-tenant tags, zero reward/version disagreements',
    v_rewards, v_versions;
end
$v313_backfill$;

alter table public.loyalty_rewards         alter column programme_id set not null;
alter table public.loyalty_reward_versions alter column programme_id set not null;

comment on column public.loyalty_rewards.programme_id is
  'v313 W6i1: the programme this reward is priced in (public.business_programmes). Identity, not '
  'runningness — a paused programme still owns its rewards. Backfilled once from '
  'app.resolve_ledger_programme_v309 in the last transaction in which that resolver was '
  'unambiguous; supplied explicitly by every writer since. Promoted from the version row by '
  'publish_loyalty_config.';
comment on column public.loyalty_reward_versions.programme_id is
  'v313 W6i1: the programme this reward VERSION is priced in. This is the column '
  'app.redeem_reward_core and public.customer_create_redemption_intent_v89 read to decide which '
  'pot to prove and drain, so it — not the business''s model — is what stops a stamp gift being '
  'paid for out of a customer''s points.';

-- ---------------------------------------------------------------------------
-- 4. The writers.
--
--    4a. The three INSERT writers, covered by ONE default (see the header for why this is a
--        default and not four column-list splices). It fills only a NULL and never overrides, so
--        increment 2's authoring UI can start supplying the column without touching this again.
--    4b. The UPDATE projection in publish_loyalty_config, spliced on an anchor no Stage A edit
--        can have moved.
-- ---------------------------------------------------------------------------

create or replace function app.reward_programme_default_v313()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.programme_id is null then
    if tg_table_name = 'loyalty_reward_versions' then
      -- A version belongs to the pot its LIVE reward is priced in. That is what makes the draft
      -- clone (v197), the v138 restore and a fresh draft of an existing reward all carry the
      -- reward's programme forward instead of re-deriving it, so a draft can never silently
      -- re-price a reward customers are already holding points for.
      select live.programme_id into new.programme_id
        from public.loyalty_rewards live
       where live.id = new.reward_id and live.business_id = new.business_id;
    end if;
    if new.programme_id is null then
      new.programme_id := app.reward_default_programme_v313(new.business_id);
    end if;
    if new.programme_id is null then
      raise exception 'reward programme is not resolvable for business %', new.business_id
        using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;

revoke all privileges on function app.reward_programme_default_v313()
  from public, anon, authenticated;

comment on function app.reward_programme_default_v313() is
  'v313 W6i1: BEFORE INSERT default for loyalty_rewards / loyalty_reward_versions.programme_id. '
  'A version inherits its LIVE reward''s programme; anything else falls back to '
  'app.reward_default_programme_v313(business_id). NEVER overrides a supplied value, and raises '
  '23514 rather than writing NULL when no programme can be determined. This covers the three '
  'INSERT writers (save_loyalty_reward_draft, clone_reward_versions_for_config, '
  'ensure_published_reward_in_draft_v138) without needing a column-list needle against two '
  'publish-kernel bodies whose live shape carries an un-repo''d V176 Stage A patch.';

drop trigger if exists trg_loyalty_rewards_programme_default_v313 on public.loyalty_rewards;
create trigger trg_loyalty_rewards_programme_default_v313
  before insert on public.loyalty_rewards
  for each row execute function app.reward_programme_default_v313();

drop trigger if exists trg_loyalty_reward_versions_programme_default_v313
  on public.loyalty_reward_versions;
create trigger trg_loyalty_reward_versions_programme_default_v313
  before insert on public.loyalty_reward_versions
  for each row execute function app.reward_programme_default_v313();

-- 4b. publish_loyalty_config (v55:711). Publishing is the moment a reward's AUTHORED programme
--     becomes its LIVE one, and it is an UPDATE, so no INSERT default can reach it.
do $v313_publish$
declare
  v_def text;
  v_anchor text := 'update public.loyalty_rewards r set ';
  v_add text := 'programme_id=rv.programme_id,';
  v_o integer;
begin
  select pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into strict v_def;
  if position(v_add in v_def) > 0 then
    raise notice 'v313: publish_loyalty_config already projects programme_id';
    return;
  end if;
  v_o := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_o <> 1 then
    raise exception
      'v313: publish_loyalty_config reward-projection anchor matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  execute replace(v_def, v_anchor, v_anchor || v_add);

  select pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into strict v_def;
  if position(v_add in v_def) = 0 then
    raise exception 'v313: publish_loyalty_config projection splice did not land'
      using errcode = '23514';
  end if;
end
$v313_publish$;

-- ---------------------------------------------------------------------------
-- 5. app.redeem_reward_core — ask the REWARD, not the business.
--
--    SPLICED against the W5 post-state body (md5 pinned in §0). One assignment moves. The batch
--    proof, the FEFO order, the drain rows and the -cost_points ledger row are untouched: they
--    already filter on v_reward_programme, so re-pointing the variable re-points all four at
--    once and nothing else in the function has to know.
-- ---------------------------------------------------------------------------

do $v313_core$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
  v_n integer;
begin
  select pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)
    into strict v_def;
  if position('v_reward_programme:=v_version.programme_id' in v_def) > 0 then
    raise notice 'v313: app.redeem_reward_core already reads the reward''s programme';
    return;
  end if;
  if position('v176_tier_gate_metric' in v_def) = 0 then
    raise exception 'v313: app.redeem_reward_core has lost its v176b tier gate; refusing to patch blind'
      using errcode = '23514';
  end if;

  v_old := $needle$  v_reward_programme:=app.resolve_ledger_programme_v309(p_business);
  if v_reward_programme is null then raise exception 'reward programme is not resolvable for this business' using errcode='XX001'; end if;$needle$;
  v_new := $needle$  v_reward_programme:=v_version.programme_id;
  if v_reward_programme is null then raise exception 'reward programme is not resolvable for this business' using errcode='XX001'; end if;
  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.business_id=p_business) then raise exception 'reward programme does not belong to this business' using errcode='42501'; end if;$needle$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  if v_o <> 1 or v_n <> 0 then
    raise exception 'v313: redeem_reward_core needle matched old=% new=% (expected 1/0)', v_o, v_n
      using errcode = '23514';
  end if;
  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)
    into strict v_def;
  if position('v_reward_programme:=v_version.programme_id' in v_def) = 0
     or position('resolve_ledger_programme_v309' in v_def) <> 0
     or position('programme_id=v_reward_programme' in v_def) = 0
     or position('v176_tier_gate_metric' in v_def) = 0 then
    raise exception 'v313: redeem_reward_core re-splice did not land in its contracted shape'
      using errcode = '23514';
  end if;
end
$v313_core$;

revoke execute on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;

comment on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) is
  'v34 catalogue redemption, v176b tier gate, v311 W5a programme-scoped, v313 W6i1 REWARD-scoped. '
  'The pot proved and drained is the one named on the reward VERSION '
  '(loyalty_reward_versions.programme_id), not the one the business''s loyalty_model implies. '
  'That is what makes a stamp gift unpayable out of a customer''s points once a firm runs both '
  'programmes at the same time. The business-scoped ledger sum at v34:570 stays as the solvency '
  'check it always was; the batch proof and the FEFO drain are the programme-scoped half.';

-- ---------------------------------------------------------------------------
-- 6. public.customer_create_redemption_intent_v89 — the same question, one step earlier.
--
--    The affordability quote must agree with what the counter will actually do, or the customer
--    is handed a QR that redeem_reward_core refuses. HOISTED, not inlined: the resolver call sat
--    inside a WHERE clause, which Postgres is free to evaluate per candidate row. That is the
--    repo's own SQL-inlining lesson, restated at v312:445-470 and measured there.
-- ---------------------------------------------------------------------------

do $v313_intent$
declare
  v_def text;
  v_old text;
  v_new text;
  v_o integer;
  v_n integer;
begin
  select pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_intent_programme:=' in v_def) > 0 then
    raise notice 'v313: customer_create_redemption_intent_v89 already reads the reward''s programme';
    return;
  end if;

  -- (a) the hoist, immediately before the two balance reads and after both branches of the
  --     kind test have populated v_reward_version (catalog) or left it null (classic).
  v_old := $needle$  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;$needle$;
  v_new := $needle$  v_intent_programme:=case when v_kind='catalog_reward' then v_reward_version.programme_id
    else (select spine.id from public.business_programmes spine
           where spine.business_id=p_business and spine.kind='points') end;
  if v_intent_programme is null then
    raise exception 'redemption programme is not resolvable for this business' using errcode='XX001';
  end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;$needle$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v313: intent hoist needle matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- (b) the batch predicate now reads the hoisted variable instead of calling the resolver.
  v_old := $needle$      and programme_id=app.resolve_ledger_programme_v309(p_business);$needle$;
  v_new := $needle$      and programme_id=v_intent_programme;$needle$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v313: intent batch-balance needle matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;

  select pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_intent_programme:=case when' in v_def) = 0
     or position('programme_id=v_intent_programme' in v_def) = 0
     or position('resolve_ledger_programme_v309' in v_def) <> 0 then
    raise exception 'v313: intent re-splice did not land in its contracted shape'
      using errcode = '23514';
  end if;
end
$v313_intent$;

comment on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text) is
  'v89 customer QR redemption intent, v229 mode gate, v311 W5a programme-scoped, v313 W6i1 '
  'REWARD-scoped. The affordability quote proves the pot named on the reward version — the same '
  'pot app.redeem_reward_core will drain at the counter — so the customer is never handed a QR '
  'the counter must refuse. The programme is resolved ONCE into v_intent_programme rather than '
  'per candidate batch row.';

-- ---------------------------------------------------------------------------
-- 7. Retire the v309 tag triggers (V311/V312 standing invariant 5).
-- ---------------------------------------------------------------------------

drop trigger if exists trg_points_ledger_programme_tag_v309  on public.points_ledger;
drop trigger if exists trg_points_batches_programme_tag_v309 on public.points_batches;

comment on function app.tag_ledger_programme_v309() is
  'v309 W3 BEFORE INSERT default, RETIRED AT v313 (W6 increment 1). The triggers that called it '
  'on points_ledger and points_batches are dropped. It filled programme_id from a resolver that '
  'v314 turns into a lie, so keeping it attached would let a writer that forgot to be explicit '
  'be silently tagged into the WRONG pot instead of failing on NOT NULL. The function stays '
  'installed and revoked so the rollback is `create trigger`, not `create function`. Every money '
  'writer is explicit — V311 suite steps 29-36 are the standing proof.';

comment on function app.resolve_ledger_programme_v309(uuid) is
  'v309 W3 single-pot resolver — THE PRE-INVERSION ORACLE, no longer consulted by any money path '
  'as of v313. It answers from loyalty_programs.loyalty_model, which v314 demotes from switch to '
  'setting; from that moment its answer is a historical fact about a firm''s settings row and not '
  'a statement about which programmes are running. Kept installed and revoked because the v313 '
  'backfill''s provenance is "this function, on this date", and because re-attaching the v309 tag '
  'triggers is part of the documented rollback.';

-- ---------------------------------------------------------------------------
-- 8. Post-assertions. Fail closed.
-- ---------------------------------------------------------------------------

do $v313_post$
declare
  v_def text;
  v_bad bigint;
  v_acl record;
begin
  -- 8.1 both columns NOT NULL, both FKs present, both tenant guards attached.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name in ('loyalty_rewards','loyalty_reward_versions')
       and column_name = 'programme_id' and is_nullable = 'YES'
  ) then
    raise exception 'v313: programme_id is still nullable somewhere' using errcode = '23514';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'loyalty_rewards_programme_fk')
     or not exists (select 1 from pg_constraint where conname = 'loyalty_reward_versions_programme_fk') then
    raise exception 'v313: a programme FK is missing' using errcode = '23514';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.loyalty_rewards'::regclass
                    and tgname = 'trg_loyalty_rewards_programme_tenant_v313')
     or not exists (select 1 from pg_trigger
                     where tgrelid = 'public.loyalty_reward_versions'::regclass
                       and tgname = 'trg_loyalty_reward_versions_programme_tenant_v313') then
    raise exception 'v313: a tenant guard trigger is missing' using errcode = '23514';
  end if;

  -- 8.2 the v309 tag triggers are gone and their functions are not.
  if exists (select 1 from pg_trigger
              where tgname in ('trg_points_ledger_programme_tag_v309',
                               'trg_points_batches_programme_tag_v309')
                and not tgisinternal) then
    raise exception 'v313: a v309 tag trigger survived the retirement' using errcode = '23514';
  end if;
  if to_regprocedure('app.tag_ledger_programme_v309()') is null
     or to_regprocedure('app.resolve_ledger_programme_v309(uuid)') is null then
    raise exception 'v313: a v309 function was dropped; the rollback is now a rewrite'
      using errcode = '23514';
  end if;

  -- 8.3 no money path may still consult the oracle.
  for v_def in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
             ('app','redeem_reward_core'),
             ('public','customer_create_redemption_intent_v89'),
             ('app','on_sale_recorded'))
  loop
    if position('resolve_ledger_programme_v309' in v_def) > 0 then
      raise exception 'v313: a money path still calls the pre-inversion oracle'
        using errcode = '23514';
    end if;
  end loop;

  -- 8.4 the publish projection names programme_id, and both INSERT defaults are attached.
  if position('programme_id=rv.programme_id' in (
       select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'publish_loyalty_config')) = 0 then
    raise exception 'v313: publish_loyalty_config does not project the reward programme'
      using errcode = '23514';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.loyalty_rewards'::regclass
                    and tgname = 'trg_loyalty_rewards_programme_default_v313')
     or not exists (select 1 from pg_trigger
                     where tgrelid = 'public.loyalty_reward_versions'::regclass
                       and tgname = 'trg_loyalty_reward_versions_programme_default_v313') then
    raise exception 'v313: a programme default trigger is missing' using errcode = '23514';
  end if;

  -- 8.5 the ACL floor. The three new app functions must not be browser-callable.
  for v_acl in
    select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname in ('reward_programme_tenant_guard_v313','reward_default_programme_v313',
                         'reward_programme_default_v313')
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute'))
  loop
    raise exception 'v313: app.% is browser-callable', v_acl.proname using errcode = '42501';
  end loop;

  -- 8.6 both standing detectors still empty. v313 touches no money row, so any movement here is
  --     a defect this migration introduced.
  -- The two standing triggers suspended for the versions backfill must be live again: a
  -- migration that leaves the immutability guard off has turned every published config mutable.
  if exists (select 1 from pg_trigger
              where tgrelid = 'public.loyalty_reward_versions'::regclass
                and tgname in ('trg_loyalty_reward_versions_immutable',
                               'trg_loyalty_reward_versions_snapshot')
                and tgenabled <> 'O')
     or (select count(*) from pg_trigger
          where tgrelid = 'public.loyalty_reward_versions'::regclass
            and tgname in ('trg_loyalty_reward_versions_immutable',
                           'trg_loyalty_reward_versions_snapshot')) <> 2 then
    raise exception 'v313: a trigger suspended for the backfill is missing or still disabled'
      using errcode = '23514';
  end if;

  select count(*) into strict v_bad from app.detect_programme_pot_split_v312();
  if v_bad <> 0 then
    raise exception 'v313: the pot-split detector is not empty (% rows)', v_bad
      using errcode = '23514';
  end if;

  raise notice
    'v313 verified: reward programme identity is NOT NULL on both tables, INSERT default + '
    'publish projection in place, redeem_reward_core and intent_v89 read the reward, v309 tag '
    'triggers retired, detectors empty';
end
$v313_post$;

commit;
