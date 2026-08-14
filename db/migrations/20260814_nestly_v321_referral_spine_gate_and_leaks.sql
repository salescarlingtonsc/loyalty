-- nestly_v321_referral_spine_gate_and_leaks
--
-- W6 WAVE 1, migration 2 of 3 (slot 20260814000300). Authority, in order:
--   scratchpad w6design/01-ORCHESTRATOR-RULINGS.md  (BINDING; overrides the contract)
--   scratchpad w6design/30-REFERRAL.md              (the implementation contract, SA-4 + D5)
--   docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md (D5 + the OWNER AMENDMENT 2026-08-14)
--
-- WHAT THIS IS. The referral payout gate stops being public.referral_programs.enabled — a column
-- that only the setup wizard ever wrote — and becomes the public.business_programmes row the
-- owner actually switches. Four proven money leaks close in the same transaction.
--
-- ============================================================================================
-- THE PROVENANCE ARGUMENT FOR THE BACKFILL, STATED FIRST BECAUSE IT IS THE WHOLE RISK CASE.
-- ============================================================================================
-- The gate move cannot change any tenant's payout behaviour, because the OLD gate
-- (referral_programs.enabled) and the NEW gate (the spine row) agree on every row of every
-- tenant at apply time. Measured live 2026-08-14 across all 11 businesses: 3 agree ON
-- (AhXiang, QA Test Cafe, ZZ-SYNTHETIC PS1B1), 8 agree OFF-with-no-row; gate_desync_rows = 0;
-- spine_on_without_row = 0. THERE IS THEREFORE NO BACKFILL AND NOTHING TO WRITE.
--
-- This migration does not ASSUME that. Step 0 measures it and raises XX001 if it is false,
-- because choosing a winner between two disagreeing gates is a money decision and belongs to a
-- human, not to a migration.
--
-- ============================================================================================
-- RULING R-A — THERE IS NO SECOND SPINE WRITER. (Overrides 30-REFERRAL §3.2/§3.3/§3.4.)
-- ============================================================================================
-- The contract proposed app.set_programme_active_v321, a shared helper callable by BOTH
-- set_programmes_v314 AND save_referral_program. That would have made save_referral_program a
-- second writer of the spine, at MANAGER permission, with no idempotency receipt — breaking
-- W6i2 standing invariant 1 ("set_programmes_v314 remains the ONE writer of the spine") and the
-- W6 brief's owner gate. IT IS NOT BUILT. This migration asserts its ABSENCE (postcondition 2).
--
-- Instead:
--   * public.set_programmes_v314 stays the only writer of public.business_programmes. It is
--     still owner-gated by app.c45_owner_loyalty_write and still receipted by
--     programme_switch_operations_v314. One needle adds the projection write beside the spine
--     UPDATE it already performs, in the same transaction as the switch.
--   * public.referral_programs.enabled becomes a PROJECTION of that spine row.
--   * public.save_referral_program writes TERMS ONLY (reward_cents, min_spend_cents). When the
--     shipped client sends p_enabled — and it will, the bundle is CDN-pinned for ~4h — the value
--     is IGNORED and the attempt is audited as REFERRAL_ENABLED_WRITE_SUPPRESSED_V321. That is
--     the same swallow+audit shape v314 used for businesses.points_mode, deliberately.
--   * A manager keeps the ability to edit referral TERMS. A manager does not gain the ability to
--     switch a programme on or off. That is the pre-existing boundary, unchanged.
--
-- HOW THE PROJECTION IS PROVED UNABLE TO DRIFT AGAIN. A detector plus a postcondition proves it
-- at apply time; neither proves it tomorrow. So the projection is also enforced STRUCTURALLY, by
-- trg_referral_programs_projection_v321 (BEFORE INSERT OR UPDATE on referral_programs), which
-- forces enabled := coalesce(spine.active, false) on every write and audits any correction it
-- had to make. Deliberately there is NO escape-hatch GUC: the projection is DEFINED as equal to
-- the spine, so no writer — not a future migration, not a service_role psql session, not a new
-- RPC — has a legitimate reason to set it to anything else. The trigger is silent in normal
-- operation (set_programmes_v314 updates the spine BEFORE it writes the projection, so it asks
-- for exactly the value the trigger computes) and speaks only when something drifts.
-- public.save_referral_program is, verified live, the ONLY function in the whole catalogue that
-- writes referral_programs, and the table has RLS with read-only policies and no INSERT/UPDATE
-- grant for anon or authenticated — so the trigger's blast radius is exactly two callers.
--
-- ============================================================================================
-- RULING R-H — THE DIVERGENCE DETECTOR IS A REPORT, NEVER AN ASSERTION.
-- ============================================================================================
-- app.detect_spine_legacy_divergence_v314() is NON-EMPTY in production right now: Cubbly /
-- tiers / spine_active=true / legacy_running=false, from a real owner's switch at 03:51:08 on
-- 2026-08-14. That is the product working exactly as V313/V314 standing invariant 5 predicted.
-- The contract's postcondition 8 asserted it empty and would have REFUSED TO APPLY. This
-- migration reads it and RAISE NOTICEs it. It never asserts it.
--
-- A consequence worth recording: after this migration v307's referral limb can never diverge
-- from the spine again, because enabled is a projection of it. That is a STRICTLY STRONGER
-- property than v307 holds for points/tiers/stamps, and app.business_programmes_v307 needs no
-- change to gain it (postcondition 11 asserts its body is byte-unchanged).
--
-- ============================================================================================
-- THE FOUR LEAKS. All four confirmed live against production 2026-08-14.
-- ============================================================================================
-- L1 — A $0 SALE QUALIFIES A PAID REFERRAL. The live predicate is
--        `if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then`
--      and with min_spend_cents = 0, `0 >= 0` is TRUE. Reachable three ways, all live:
--      public.staff_redeem_welcome_offer_v215 inserts a $0 sale of kind service/retail (verified
--      live body), and app.sale_policy_defaults() gives both kinds counts_as_visit = true;
--      use_package_session inserts a $0 kind='service' sale; and any future $0 sale.
--      QA TEST CAFE (dcaaf5d6) IS LIVE TODAY WITH enabled=true, reward_cents=1000,
--      min_spend_cents=0 — a $0 welcome-offer redemption there pays $10 of real store credit.
--      Fix: one predicate, `new.amount_cents>0`. A firm that set min_spend_cents = 0 meant "any
--      visit qualifies", and a $0 visit is still not a visit worth $10.
-- L2 — REVERSAL RE-ARMS THE REFERRAL FOR A SECOND PAYOUT. reverse_sale_v20_base sets the
--      referral back to status='pending' and nulls qualified_at/qualified_sale_id/reward_cents.
--      The earn path filters exactly status='pending', so the same referral pays AGAIN on the
--      next visit. Fix: terminal status='reversed' (ruling R-D / contract R2), with
--      public.staff_rearm_referral_v321 as the audited escape hatch.
-- L3 — THE CLAWBACK HAS NO SPENT-CREDIT GUARD. The insert of -reward_cents is unconditional; if
--      the referrer already spent the credit, client_credit_balance goes NEGATIVE. Fix: clamp to
--      greatest(0, least(reward_cents, balance)), SKIP the insert entirely when that is 0 — the
--      write guard's sale_reversal branch requires amount_cents <> 0, so a clamp-to-zero insert
--      is ILLEGAL, not merely wasteful — and audit REFERRAL_CLAWBACK_SHORTFALL_V321 either way.
-- L4 — THE SWITCH DESYNC ITSELF. This is SA-4, above.
-- L5 is ALREADY CLOSED and is NOT rebuilt: one-per-customer idempotency is structural, via the
--      unique INDEX one_referral_per_referred (an index, not a constraint — it will not appear
--      in pg_constraint, so do not go looking for it there).
--
-- ============================================================================================
-- DELIBERATELY DEFERRED TO v327 (nestly_v327_referral_both_sides_and_join_capture, WAVE 3).
-- ============================================================================================
-- Ruling R-D adopts the full D5 money semantics, but this migration ships only what its own
-- scope needs. Everything below is v327's, and is NOT half-built here — no lie-columns, no
-- unenforced defaults:
--   * THE FRIEND-SIDE GRANT: credit_ledger.entry_type='referral_friend_reward', the write-guard
--     branch, referral_programs.friend_reward_cents, referrals.friend_reward_cents, and the
--     on_sale_recorded friend leg.
--   * THE FRIEND-SIDE CLAWBACK, clamped and audited exactly like the referrer's (R3/R-D). It
--     cannot ship before the grant it compensates: there is no friend amount to claw back until
--     friend_reward_cents exists.
--   * business_welcome_offers_v215.referral_precedence (default 'referral_wins', R4/R-D),
--     enforced at grant/attach time only. Its two enforcement points are
--     app.issue_welcome_offer_v215 and the v327 attach helper; shipping the column here with
--     neither would be a setting that does nothing. Zero welcome offers exist in production, so
--     it still ships before it can bite anyone.
--   * Join-time capture (app.attach_referral_v320, p_referral_code on internal_public_join_v89,
--     the join.html field, the public-join edge redeploy STRICTLY AFTER that migration, and
--     customer_apply_referral_code_v320).
-- v327 is the SECOND editor of app.on_sale_recorded and reverse_sale_v20_base after this one and
-- must pin the post-apply md5s this migration RAISE NOTICEs at the end.
--
-- ============================================================================================
-- WHAT THIS MIGRATION DOES NOT CHANGE, STATED SO A LATER READER DOES NOT "TIDY IT UP".
-- ============================================================================================
-- * NO enabled_modules CHECK IS ADDED TO THE ENGINE. CLAUDE.md's own rule is that turning a
--   module off in Settings must not strand rows, and stopping an in-flight referral because
--   someone unticked a checkbox is a silent money change. The resulting asymmetry with
--   customer_get_referral_card_v300 (which DOES check the module) is surfaced by the detector's
--   module_off_with_spine_on limb rather than papered over.
-- * referrals.status = 'qualified' remains a value NOTHING writes (a pre-existing vestige). It is
--   tempting to use it for "spent enough, nothing payable", but that would make the referral
--   TERMINAL and the referrer would never be paid after the firm configures a reward. 'pending'
--   is forgiving and matches today.
-- * A REVERSED REFERRAL KEEPS reward_cents AND qualified_sale_id. Only status moves. Today's
--   re-arm nulls all three and destroys the record of what was paid; keeping them makes the
--   shortfall audit reconcilable and makes a double reversal structurally impossible (the
--   re-entry guard matches status='rewarded', which a reversed row no longer is).
-- * public.save_referral_program keeps its 4-arg signature, its name and its ACL, so no client
--   change is required by v321 and there is no PGRST203 window.
-- * app.enqueue_programme_pot_migration_v312 is untouched and stays inside set_programmes_v314
--   (V311/V312 standing invariant 2). Referral is not an accruing kind and routes no pot.
-- * PROGRAMME_PUBLISH_KINDS_W6I2 stays at three kinds (ruling R-B). Its CORRECTNESS reason dies
--   here; a PRODUCT reason replaces it — referral settings are not in the version kernel, so
--   publishing a loyalty draft is not a statement about referral. The client wave rewrites that
--   comment; do not delete the constant on SA-4's strength.
--
-- Value tables: this migration writes NO sales, credit_ledger, points_ledger or points_batches
-- row. It adds two columns and a CHECK to public.referrals (a non-value table), one trigger and
-- one comment on public.referral_programs, two functions, and splices four function bodies.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition. Added after the 2026-08-14 production deadlocks (three
-- consecutive 40P01s, same signature each time): the live media pipeline
-- public.business_publish_media_replacement_v95 holds storage.objects while reading inside one
-- transaction, and interleaving lock acquisition with it deadlocks. Taking every contested
-- relation up front, in one ordered LOCK, makes a cycle impossible. storage.objects is locked
-- conditionally because verification rigs replay only the app/public schemas.
--
-- The ORDER is V308 standing invariant 1 restated: public.businesses first, before any spine
-- row, then the spine, then the projection it drives, then referrals.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v319_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v319_prelock$;

lock table public.businesses, public.business_programmes,
           public.referral_programs, public.referrals
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- 0. Preconditions. Every md5 is read LIVE here, into a temp table, and the "no-touch"
--    postconditions assert equality against THAT snapshot rather than against a transcribed
--    literal (ruling R-G). A hardcoded literal would claim "nobody in the wave touched it",
--    which no migration is entitled to claim.
--
--    The predecessor pins below ARE literals, and that is the opposite case and correct: they
--    say "the body I am about to splice is the body I read when I wrote these needles". They
--    fail closed.
-- ---------------------------------------------------------------------------

create temp table v319_pins(key text primary key, value text) on commit drop;

do $v319_pre$
declare
  v_md5 text;
  v_bad bigint;
  v_row record;
begin
  -- 0.1 Self-refusal. This migration is one-apply: the CHECK swap and the column adds are
  --     idempotent-ish, the splices are individually idempotent, but the story is not.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'referrals' and column_name = 'reversed_at'
  ) then
    raise exception 'v321 is already applied (public.referrals.reversed_at exists)'
      using errcode = '23514';
  end if;

  -- 0.2 The predecessors this wave is built on.
  if to_regclass('public.business_programmes') is null then
    raise exception 'v321: the v308 programme spine is absent' using errcode = '42P01';
  end if;
  if to_regprocedure('public.set_programmes_v314(uuid,jsonb,uuid)') is null then
    raise exception 'v321: v314 has not been applied (set_programmes_v314 is missing)'
      using errcode = '42883';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.businesses'::regclass
                    and tgname = 'business_programmes_seed_v314') then
    raise exception 'v321: the v314 seed trigger is missing (standing invariant 4)'
      using errcode = '23514';
  end if;

  -- 0.3 RAW md5 predecessor pins on the four bodies this migration edits. RAW, not normalised:
  --     the contract's own correction records that stripped md5 does not reproduce against
  --     production for reverse_sale_v20_base, because the strip regexes differ between rigs.
  for v_row in
    select * from (values
      ('app.on_sale_recorded()',                                        '094f7f8e2be24cea0a8d9d3e8fbacfdc'),
      ('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)',   'b905f3b5225363f76fe873562ea1a1fd'),
      ('public.save_referral_program(uuid,boolean,integer,integer)',    '6e49bccd61d658f5773b92fc8009fdab'),
      ('public.set_programmes_v314(uuid,jsonb,uuid)',                   'fe0d353ec384d84540fa5717fadec307')
    ) pins(signature, expected)
  loop
    if to_regprocedure(v_row.signature) is null then
      raise exception 'v321: splice target is missing: %', v_row.signature using errcode = '42883';
    end if;
    select md5(p.prosrc) into strict v_md5 from pg_proc p where p.oid = to_regprocedure(v_row.signature);
    if v_md5 <> v_row.expected then
      raise exception 'v321: % is not the expected pre-state body (md5=% expected=%)',
        v_row.signature, v_md5, v_row.expected using errcode = '23514';
    end if;
  end loop;

  -- 0.4 SNAPSHOT PINS (ruling R-G). Read now, asserted equal at the end. These are the bodies
  --     this migration promises NOT to touch.
  insert into v319_pins(key, value)
  select 'app.business_programmes_v307', md5(p.prosrc)
    from pg_proc p where p.oid = to_regprocedure('app.business_programmes_v307(uuid)');
  insert into v319_pins(key, value)
  select 'app.loyalty_ledger_write_guard', md5(p.prosrc)
    from pg_proc p where p.oid = to_regprocedure('app.loyalty_ledger_write_guard()');
  insert into v319_pins(key, value)
  select 'public.customer_get_referral_card_v300', md5(p.prosrc)
    from pg_proc p where p.oid = to_regprocedure('public.customer_get_referral_card_v300(text)');
  insert into v319_pins(key, value)
  select 'app.detect_spine_legacy_divergence_v314', md5(p.prosrc)
    from pg_proc p where p.oid = to_regprocedure('app.detect_spine_legacy_divergence_v314()');
  if (select count(*) from v319_pins) <> 4 then
    raise exception 'v321: a snapshot pin target is missing' using errcode = '42883';
  end if;

  -- 0.5 The ACL of the function about to be re-bodied. `create or replace` preserves ACL, so
  --     this is belt and braces — but a silent ACL move on a browser-callable money-adjacent
  --     RPC is exactly the class of change that must never happen by accident.
  insert into v319_pins(key, value)
  select 'acl:public.save_referral_program',
         coalesce((select string_agg(pg_get_userbyid(a.grantee)||':'||a.privilege_type, ',' order by 1)
                     from aclexplode(p.proacl) a), '')
    from pg_proc p where p.oid = to_regprocedure('public.save_referral_program(uuid,boolean,integer,integer)');

  -- 0.6 THE BACKFILL PROOF. Both assertion limbs of the gate must already be empty. If they are
  --     not, the two gates disagree somewhere and a human has to decide which one is the truth
  --     — this migration will not guess, because guessing here pays or withholds real money.
  select count(*) into v_bad
    from public.business_programmes spine
    join public.referral_programs rp on rp.business_id = spine.business_id
   where spine.kind = 'referral'
     and spine.active is distinct from coalesce(rp.enabled, false);
  if v_bad <> 0 then
    raise exception
      'v321: % tenant(s) disagree between the spine referral row and referral_programs.enabled. '
      'Choosing a winner is a money decision and belongs to a human, not to this migration.', v_bad
      using errcode = 'XX001';
  end if;

  select count(*) into v_bad
    from public.business_programmes spine
   where spine.kind = 'referral' and spine.active
     and not exists (select 1 from public.referral_programs rp where rp.business_id = spine.business_id);
  if v_bad <> 0 then
    raise exception 'v321: % tenant(s) have the referral spine ON with no referral_programs row', v_bad
      using errcode = 'XX001';
  end if;

  -- 0.7 The standing detectors that ARE assertions.
  select count(*) into v_bad from app.detect_programme_pot_split_v312();
  if v_bad <> 0 then
    raise exception 'v321: the pot-split detector is not empty (% rows)', v_bad using errcode = '23514';
  end if;
  select count(*) into v_bad from app.detect_double_earn_v309();
  if v_bad <> 0 then
    raise exception 'v321: the double-earn detector is not empty (% rows)', v_bad using errcode = '23514';
  end if;

  -- 0.8 RULING R-H: the spine/legacy divergence detector is READ AND REPORTED. Never asserted.
  --     It is non-empty in production today (Cubbly / tiers) and that is the product working.
  for v_row in select * from app.detect_spine_legacy_divergence_v314() loop
    raise notice 'v321 pre-flight REPORT (not an assertion): spine/legacy divergence % / % / spine=% legacy=%',
      v_row.business_name, v_row.kind, v_row.spine_active, v_row.legacy_running;
  end loop;

  raise notice 'v321 pre-flight clean: 4 predecessor pins matched, 4 snapshot pins captured, '
               'referral gate desync = 0, pot-split = 0, double-earn = 0';
end
$v319_pre$;

-- ---------------------------------------------------------------------------
-- 1. Terminal 'reversed' (leak L2). Ruling R-D / contract R2.
--
--    public.referrals holds 2 rows in production, both 'rewarded' with no reversal, so both the
--    widened CHECK and the new shape CHECK validate instantly.
-- ---------------------------------------------------------------------------

alter table public.referrals drop constraint referrals_status_check;
alter table public.referrals add constraint referrals_status_check
  check (status = any (array['pending'::text, 'qualified'::text, 'rewarded'::text, 'reversed'::text]));

alter table public.referrals add column reversed_at timestamptz;
alter table public.referrals add column reversed_sale_id uuid;

-- Same-tenant FK, matching referrals_qualified_sale_same_tenant. public.sales carries the
-- (id, business_id) unique key this needs; a reversal is a compensating sale ROW, not a delete.
alter table public.referrals add constraint referrals_reversed_sale_same_tenant
  foreign key (reversed_sale_id, business_id) references public.sales (id, business_id);

-- The shape rule, machine-checked in both directions: a reversed referral always carries its
-- timestamp, and a non-reversed one never does. staff_rearm_referral_v321 clears both together.
alter table public.referrals add constraint referrals_reversed_shape_v321
  check ((status = 'reversed') = (reversed_at is not null));

comment on column public.referrals.reversed_at is
  'Set by public.reverse_sale_v20_base when the qualifying sale is reversed (v321). Terminal: '
  'the earn path filters status=''pending'', so a reversed referral can never pay a second time. '
  'public.staff_rearm_referral_v321 is the audited manual route back into the pool.';

-- ---------------------------------------------------------------------------
-- 2. The projection, and the structural proof that it can never drift.
--
--    public.referral_programs.enabled is, from here, a projection of the referral spine row.
--    Ruling R-A gives it exactly one intended writer (public.set_programmes_v314, §5 below).
--    This trigger is what makes "exactly one writer" a PROPERTY OF THE DATABASE rather than a
--    property of the code review that let the change in.
-- ---------------------------------------------------------------------------

comment on column public.referral_programs.enabled is
  'PROJECTION of public.business_programmes(kind=''referral'').active since v321. The ENGINE '
  '(app.on_sale_recorded) gates on the SPINE, never on this column. This column exists so '
  'app.business_programmes_v307, public.customer_get_referral_card_v300 and the browser keep '
  'answering the same question. It is written only by public.set_programmes_v314; every other '
  'write is forced back onto the spine value by trg_referral_programs_projection_v321 and '
  'audited as REFERRAL_ENABLED_WRITE_SUPPRESSED_V321. '
  'app.detect_referral_gate_desync_v321() asserts the two can never diverge.';

create or replace function app.referral_programs_projection_v321()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $v319_projection$
declare
  v_spine boolean;
begin
  -- The spine is authority. A business with no spine referral row is not running referral, so
  -- coalesce(...,false) is the honest projection rather than a fallback. The v314 seed trigger
  -- on public.businesses guarantees the row exists for every tenant created after v314, and
  -- postcondition 13 proves it exists for every tenant that predates it.
  select spine.active into v_spine
    from public.business_programmes spine
   where spine.business_id = new.business_id and spine.kind = 'referral';
  v_spine := coalesce(v_spine, false);

  if new.enabled is distinct from v_spine then
    -- Only speaks when a writer asked for something the spine does not say. In normal operation
    -- (set_programmes_v314 updates the spine BEFORE writing the projection; save_referral_program
    -- leaves enabled out of its DO UPDATE list) this branch is never taken.
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (new.business_id, auth.uid(), 'REFERRAL_ENABLED_WRITE_SUPPRESSED_V321',
            'referral_programs', new.id,
            jsonb_build_object('attempted', new.enabled, 'kept', v_spine,
                               'source', 'referral_programs_projection_v321',
                               'op', tg_op));
    new.enabled := v_spine;
  end if;
  return new;
end
$v319_projection$;

comment on function app.referral_programs_projection_v321() is
  'v321 SA-4: forces public.referral_programs.enabled to equal the referral spine row on every '
  'write. There is deliberately NO escape-hatch GUC — the projection is DEFINED as equal to the '
  'spine, so no writer has a legitimate reason to set it otherwise. Any correction is audited.';

revoke all on function app.referral_programs_projection_v321() from public, anon, authenticated;

drop trigger if exists trg_referral_programs_projection_v321 on public.referral_programs;
create trigger trg_referral_programs_projection_v321
  before insert or update on public.referral_programs
  for each row execute function app.referral_programs_projection_v321();

-- ---------------------------------------------------------------------------
-- 3. The standing detector. Two ASSERTION limbs (must be zero rows forever) and two REPORT
--    limbs (states a firm can legitimately be in, which an operator should be able to see).
--
--    STANDING INVARIANT for every later increment: the two assertion limbs must be zero rows on
--    every future migration's pre-flight. A non-zero row means a writer of
--    referral_programs.enabled or business_programmes.active was added outside
--    public.set_programmes_v314.
-- ---------------------------------------------------------------------------

create or replace function app.detect_referral_gate_desync_v321()
returns table (business_id uuid, business_name text, reason text,
               spine_active boolean, legacy_enabled boolean,
               has_programme_row boolean, module_enabled boolean,
               reward_cents integer, pending_referrals integer)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $v319_detect$
  with base as (
    select b.id, b.name,
           coalesce((select spine.active from public.business_programmes spine
                      where spine.business_id = b.id and spine.kind = 'referral'), false) as spine_active,
           rp.enabled as legacy_enabled,
           (rp.business_id is not null) as has_row,
           ('referrals' = any(b.enabled_modules)) as module_enabled,
           coalesce(rp.reward_cents, 0) as reward_cents,
           (select count(*)::integer from public.referrals r
             where r.business_id = b.id and r.status = 'pending') as pending
      from public.businesses b
      left join public.referral_programs rp on rp.business_id = b.id
  )
  -- ASSERTION: the row exists and the two gates disagree.
  select id, name, 'spine_vs_enabled', spine_active, legacy_enabled, has_row, module_enabled,
         reward_cents, pending
    from base where has_row and spine_active is distinct from coalesce(legacy_enabled, false)
  union all
  -- ASSERTION: spine on, no terms row at all — v307 would say false while the spine says true.
  select id, name, 'spine_on_without_row', spine_active, legacy_enabled, has_row, module_enabled,
         reward_cents, pending
    from base where spine_active and not has_row
  union all
  -- REPORT: on, capturing referrals, paying nothing. A legal state (see §6) and the owner is
  -- told about it in copy; an operator should still be able to list it.
  select id, name, 'on_without_reward', spine_active, legacy_enabled, has_row, module_enabled,
         reward_cents, pending
    from base where spine_active and reward_cents = 0
  union all
  -- REPORT: the engine pays while the customer-facing card is hidden. This is the deliberate
  -- asymmetry recorded in the header — the engine does not read enabled_modules, the card does.
  select id, name, 'module_off_with_spine_on', spine_active, legacy_enabled, has_row, module_enabled,
         reward_cents, pending
    from base where spine_active and not module_enabled
  order by 3, 2
$v319_detect$;

comment on function app.detect_referral_gate_desync_v321() is
  'v321 SA-4 standing detector. reason in (spine_vs_enabled, spine_on_without_row) are '
  'ASSERTIONS — zero rows forever; a row means a second writer of referral_programs.enabled or '
  'business_programmes.active was introduced. reason in (on_without_reward, '
  'module_off_with_spine_on) are REPORTS of legal states. Operator tool, not a browser RPC.';

revoke all on function app.detect_referral_gate_desync_v321() from public, anon, authenticated;
grant execute on function app.detect_referral_gate_desync_v321() to postgres, service_role;

-- ---------------------------------------------------------------------------
-- 4. Splice public.set_programmes_v314 — the ONE spine writer also writes the projection.
--
--    Needle S1, occurrence count 1, verified live. The anchor is the v_changes accumulator line,
--    which sits immediately AFTER the spine UPDATE and immediately BEFORE the audit INSERT. That
--    position is load-bearing: the spine must already hold the new value when the projection is
--    written, so the projection trigger computes the same answer the switch asked for and stays
--    silent. Suite cell 11 proves the ordering behaviourally.
--
--    Everything else in set_programmes_v314 — the owner gate, the idempotency receipt, the
--    businesses FOR UPDATE, the v307 self-heal, the kind ordering, the breadcrumbs, the pot
--    routing block and the result envelope — is UNTOUCHED. The whole v313/v314 suite (35 steps,
--    18 mutants) is the regression net and must be re-run green against this body.
-- ---------------------------------------------------------------------------

do $v319_spine$
declare
  v_def text;
  v_o integer;
  v_old text := $needle$      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);$needle$;
  v_new text := $needle$      if v_kind = 'referral' then
        -- SA-4 (v321): referral_programs.enabled is a PROJECTION of this spine row, written in
        -- the same transaction as the switch, by the switch's own writer. reward_cents = 0 on
        -- the seed and NOT the column default of 1000: never invent a payout — a firm that
        -- flips a toggle must not silently commit to $10. Only `enabled` is in the DO UPDATE
        -- list, so an existing firm's terms are never touched.
        insert into public.referral_programs (business_id, enabled, reward_cents, min_spend_cents)
        values (p_business, v_want, 0, 0)
        on conflict (business_id) do update set enabled = excluded.enabled;
      end if;
      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);$needle$;
begin
  select pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure) into strict v_def;
  if position($guard$insert into public.referral_programs (business_id, enabled, reward_cents, min_spend_cents)$guard$ in v_def) > 0 then
    raise notice 'v321: set_programmes_v314 already writes the referral projection';
    return;
  end if;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v321: set_programmes_v314 needle S1 matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  execute replace(v_def, v_old, v_new);
end
$v319_spine$;

-- ---------------------------------------------------------------------------
-- 5. public.save_referral_program — TERMS ONLY. Signature, name and ACL unchanged.
--
--    RULING R-A. The shipped bundle still sends p_enabled and is CDN-pinned for ~4h, so the
--    argument is kept and IGNORED rather than removed. Removing it would be a PGRST202/PGRST203
--    window on a live owner surface; ignoring it is a no-op for a client that was already
--    writing a column the engine no longer reads.
--
--    THE AUTH GATE IS DELIBERATELY NOT NARROWED to app.c45_owner_loyalty_write. A manager
--    holding the referrals module can save referral TERMS today and must keep being able to.
--    What a manager does NOT get is the switch — and the reason that is now safe to say plainly
--    is that this function no longer touches the switch at all.
--
--    The returned `enabled` is re-read from the row AFTER the write, so it is never optimistic:
--    a manager who sends p_enabled=true at an off firm gets back enabled=false and the page
--    re-renders the truth.
-- ---------------------------------------------------------------------------

create or replace function public.save_referral_program(
  p_business uuid, p_enabled boolean, p_reward_cents integer, p_min_spend_cents integer
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $v319_save_referral$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_program public.referral_programs%rowtype;
  v_spine boolean;
begin
  if v_actor is null or not app.can_module_write(p_business, 'referrals') then
    raise exception 'active referrals-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if p_enabled is null or p_reward_cents is null or p_reward_cents < 0
     or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;

  -- Lock order, stated as a rule so a later editor keeps the prefix: staff FOR UPDATE ->
  -- businesses FOR UPDATE -> business_programmes -> referral_programs. public.set_programmes_v314
  -- takes businesses -> business_programmes -> referral_programs. A consistent prefix, so no
  -- cycle. V308 standing invariant 1 (businesses FOR UPDATE first, before any spine row) holds
  -- in both paths.
  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    raise exception 'business does not exist' using errcode = '42501';
  end if;

  select spine.active into v_spine
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'referral';
  v_spine := coalesce(v_spine, false);

  -- SA-4 (v321), ruling R-A: the switch is NOT ours to move. public.set_programmes_v314 is the
  -- one writer of the programme spine, owner-gated and receipted. A p_enabled that disagrees
  -- with the spine is swallowed and audited — the same shape v314 used for businesses.points_mode
  -- — because the shipped client still sends it.
  if p_enabled is distinct from v_spine then
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'REFERRAL_ENABLED_WRITE_SUPPRESSED_V321', 'referral_programs',
            p_business,
            jsonb_build_object('attempted', p_enabled, 'kept', v_spine,
                               'source', 'save_referral_program',
                               'note', 'the referral switch moves only through set_programmes_v314'));
  end if;

  -- TERMS ONLY. `enabled` is absent from the DO UPDATE list. On a fresh INSERT it is seeded from
  -- the spine, and trg_referral_programs_projection_v321 forces that value regardless.
  insert into public.referral_programs (business_id, enabled, reward_cents, min_spend_cents)
  values (p_business, v_spine, p_reward_cents, p_min_spend_cents)
  on conflict (business_id) do update set
    reward_cents = excluded.reward_cents,
    min_spend_cents = excluded.min_spend_cents
  returning * into v_program;

  return jsonb_build_object('status','completed','program_id',v_program.id,
    'enabled',v_program.enabled,'reward_cents',v_program.reward_cents,
    'min_spend_cents',v_program.min_spend_cents);
end
$v319_save_referral$;

comment on function public.save_referral_program(uuid, boolean, integer, integer) is
  'v321: writes referral TERMS only. p_enabled is accepted for the CDN-pinned client and '
  'ignored; the switch moves only through public.set_programmes_v314 (ruling R-A). Kept at four '
  'arguments deliberately — a signature change here is a PGRST203 window on a live owner page.';

-- The ACL is restated rather than inherited. `create or replace` PRESERVES the existing grants,
-- so against production these two statements are a no-op that lands the SAME grantee set
-- postcondition 13 pins ({authenticated, postgres, service_role}, measured live). They are
-- mandatory anyway: if this function were ever created fresh — a rebuilt environment, a replay
-- against an empty catalogue — PostgreSQL's default EXECUTE grant to PUBLIC would make a
-- SECURITY DEFINER money-adjacent RPC callable by anon. Spelling the revoke is what
-- tests/phase0-foundation/pending-migration-preflight.test.mjs enforces, and it is right to.
revoke all on function public.save_referral_program(uuid, boolean, integer, integer)
  from public, anon;
grant execute on function public.save_referral_program(uuid, boolean, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Splice app.on_sale_recorded — the gate move (L4) plus L1 plus the "on with no terms" hole.
--
--    Needle E1, occurrence count 1, verified live. ONE needle closes three things:
--
--    a) L4 — the gate is the SPINE. referral_programs is still read, for the TERMS, never for
--       the switch. `and enabled` leaves the lookup.
--    b) L1 — `new.amount_cents>0`. A $0 sale can no longer qualify a paid referral.
--    c) THE OUTAGE SHAPE — `coalesce(refprog.reward_cents,0)>0`. Without it, a firm that is
--       switched ON with no reward configured would attempt a credit_ledger insert of
--       amount_cents = 0, which app.loyalty_ledger_write_guard's sale_trigger branch rejects
--       with check_violation — and because the guard runs inside the sale's own AFTER INSERT
--       trigger, that would FAIL THE WHOLE SALE INSERT. A till outage, caused by a toggle.
--       Mutant M4 of the suite proves that shape is real.
--
--    The resulting legal state — referral ON with reward_cents = 0 — CAPTURES the referral,
--    pays nothing, and leaves it 'pending' so it qualifies later once a reward is configured.
--    That is byte-identical to today's Off behaviour and to the copy the product already ships
--    ("Referral links are saved, but no reward is paid while it remains Off"). It is surfaced by
--    the detector's on_without_reward limb, and the client wave owes it one honest line on the
--    Referrals page.
--
--    Deliberately unchanged: the block still lives inside `if new.counts_as_visit then`, and it
--    still does the refrow lookup first. refprog is used only for reward_cents/min_spend_cents
--    downstream, so dropping `and enabled` from the SELECT changes nothing else.
-- ---------------------------------------------------------------------------

do $v319_engine$
declare
  v_def text;
  v_o integer;
  v_old text := $needle$      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then$needle$;
  v_new text := $needle$      select * into refprog from public.referral_programs where business_id=new.business_id limit 1;
      if found and coalesce(refprog.reward_cents,0)>0 and new.amount_cents>0
         and new.amount_cents>=coalesce(refprog.min_spend_cents,0)
         and exists(select 1 from public.business_programmes spine where spine.business_id=new.business_id and spine.kind='referral' and spine.active) then$needle$;
begin
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position($guard$spine.kind='referral' and spine.active$guard$ in v_def) > 0 then
    raise notice 'v321: app.on_sale_recorded already gates referral on the spine';
    return;
  end if;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v321: on_sale_recorded needle E1 matched % times (expected 1)', v_o
      using errcode = '23514';
  end if;
  execute replace(v_def, v_old, v_new);
end
$v319_engine$;

-- ---------------------------------------------------------------------------
-- 7. Splice public.reverse_sale_v20_base — L2 (terminal reversed) and L3 (clamped clawback).
--
--    SIX counted needles against the LIVE body. No repo file reproduces this function (25 111
--    bytes, carrying edits applied by asserted string replacement against production), so the
--    splices are written against prosrc read live and the original indentation of untouched
--    lines is preserved. A splice is about bytes, not beauty.
--
--    THE CLAMP READS THE REFERRER'S WHOLE BALANCE, not just referral_reward rows: credit is
--    fungible and the question is "can this customer give it back", not "is that exact row still
--    there". The read happens BEFORE the payments loop and BEFORE any credit restoration, i.e.
--    the balance as it stands at the moment of clawback. The reversed sale's buyer is the
--    REFERRED client and the clawback target is the REFERRER — different clients by construction
--    (staff_create_client refuses self-referral) — so the two ledger effects cannot interact.
--
--    A CLAMP TO ZERO MUST SKIP THE INSERT ENTIRELY. app.loyalty_ledger_write_guard's
--    sale_reversal branch requires amount_cents <> 0, so a 0-amount compensating row is not
--    merely pointless, it is a check_violation that would abort the whole reversal. Mutant M7
--    proves it.
-- ---------------------------------------------------------------------------

do $v319_reversal$
declare
  v_def text;
  v_o integer;
  v_target record;
begin
  select pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)
    into strict v_def;
  if position($guard$REFERRAL_CLAWBACK_SHORTFALL_V321$guard$ in v_def) > 0 then
    raise notice 'v321: reverse_sale_v20_base already carries the clamped clawback';
    return;
  end if;

  for v_target in
    select * from (values
      -- R1. Declarations.
      (1, $needle$  v_referral public.referrals%rowtype;
begin$needle$,
          $needle$  v_referral public.referrals%rowtype;
  v_referral_clawback_cents integer := 0;
  v_referral_shortfall_cents integer := 0;
begin$needle$),

      -- R2. Compute the clamp, then OPEN an inner guard around the ledger insert so a
      --     zero-recovery case skips it entirely.
      (2, $needle$  if found and coalesce(v_referral.reward_cents, 0) > 0 then
    v_credit_id := gen_random_uuid();
    v_credit_key := 'v20:' || v_operation.id || ':referral:' || v_referral.id;$needle$,
          $needle$  if found and coalesce(v_referral.reward_cents, 0) > 0 then
    select greatest(0, least(coalesce(v_referral.reward_cents, 0),
                             coalesce(sum(cl.amount_cents), 0)::integer))
      into v_referral_clawback_cents
      from public.credit_ledger cl
     where cl.business_id = o.business_id
       and cl.client_id = v_referral.referrer_client_id;
    v_referral_shortfall_cents := coalesce(v_referral.reward_cents, 0) - v_referral_clawback_cents;
    if v_referral_clawback_cents > 0 then
    v_credit_id := gen_random_uuid();
    v_credit_key := 'v20:' || v_operation.id || ':referral:' || v_referral.id;$needle$),

      -- R3. The compensating amount.
      (3, $needle$      'manual_adjust',
      -v_referral.reward_cents,
      'sale reversal: referral reward clawback for sale ' || o.id,$needle$,
          $needle$      'manual_adjust',
      -v_referral_clawback_cents,
      'sale reversal: referral reward clawback for sale ' || o.id,$needle$),

      -- R4. The immutable-child comparison on replay must compare the SAME clamped amount, or a
      --     legitimate replay would raise 23505 against its own earlier row.
      (4, $needle$            (v_referral.referrer_client_id, 'manual_adjust'::text,
             -v_referral.reward_cents, v_reversal.id, null::uuid, v_actor) then$needle$,
          $needle$            (v_referral.referrer_client_id, 'manual_adjust'::text,
             -v_referral_clawback_cents, v_reversal.id, null::uuid, v_actor) then$needle$),

      -- R5. Close the inner guard, audit any shortfall, and make the status TERMINAL.
      --     v_referral_reversed := true is now OUTSIDE the clawback guard: the referral WAS
      --     reversed even when nothing was recoverable, and sale_reversal_audits.referral_reversed
      --     must say so.
      (5, $needle$    update public.referrals
       set status = 'pending',
           qualified_at = null,
           qualified_sale_id = null,
           reward_cents = 0
     where id = v_referral.id;
    v_referral_reversed := true;
  end if;$needle$,
          $needle$    end if;
    if v_referral_shortfall_cents > 0 then
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      values (o.business_id, v_actor, 'REFERRAL_CLAWBACK_SHORTFALL_V321', 'referrals', v_referral.id,
              jsonb_build_object('reward_cents', coalesce(v_referral.reward_cents, 0),
                                 'recovered_cents', v_referral_clawback_cents,
                                 'shortfall_cents', v_referral_shortfall_cents,
                                 'referrer_client_id', v_referral.referrer_client_id,
                                 'original_sale_id', o.id,
                                 'reversal_sale_id', v_reversal.id));
    end if;
    update public.referrals
       set status = 'reversed',
           reversed_at = now(),
           reversed_sale_id = v_reversal.id
     where id = v_referral.id;
    v_referral_reversed := true;
  end if;$needle$),

      -- R6. The result envelope. MANDATORY, not optional: a partial recovery that is invisible in
      --     the operation result is exactly what becomes an incident three months later. Both
      --     keys also land in sale_reversal_audits.effects, which stores this same jsonb.
      (6, $needle$    'referral_reversed', v_referral_reversed,$needle$,
          $needle$    'referral_reversed', v_referral_reversed,
    'referral_clawback_cents', v_referral_clawback_cents,
    'referral_shortfall_cents', v_referral_shortfall_cents,$needle$)
    ) targets(ord, old_text, new_text)
    order by ord
  loop
    v_o := (length(v_def) - length(replace(v_def, v_target.old_text, ''))) / length(v_target.old_text);
    if v_o <> 1 then
      raise exception 'v321: reverse_sale_v20_base needle R% matched % times (expected 1)',
        v_target.ord, v_o using errcode = '23514';
    end if;
    v_def := replace(v_def, v_target.old_text, v_target.new_text);
  end loop;

  execute v_def;
end
$v319_reversal$;

-- ---------------------------------------------------------------------------
-- 8. public.staff_rearm_referral_v321 — the escape hatch for the new terminal state.
--
--    Ruling R-D / contract R2. A terminal state with no manual route strands a referrer's money
--    after a mis-keyed refund, and the unique index one_referral_per_referred blocks simply
--    re-linking the friend. Same permission that reversed it (refund_sales = owner + manager,
--    verified live in app.role_perms), a real reason, and an audit row.
--
--    Here the fields ARE cleared: the referral is going back into the pool and must be
--    indistinguishable from a fresh one to the earn path. That is the opposite of the reversal's
--    rule, and deliberately so — a reversal is a RECORD, a re-arm is a RESET.
-- ---------------------------------------------------------------------------

create or replace function public.staff_rearm_referral_v321(
  p_business uuid, p_referral uuid, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $v319_rearm$
declare
  v_actor uuid := auth.uid();
  v_referral public.referrals%rowtype;
begin
  if v_actor is null or p_business is null or p_referral is null then
    raise exception 'business and referral are required' using errcode = '22023';
  end if;
  if not app.has_perm(p_business, 'refund_sales') then
    raise exception 'refund authorization is required to re-arm a referral' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required' using errcode = '22023';
  end if;

  select * into v_referral from public.referrals r
   where r.id = p_referral and r.business_id = p_business and r.status = 'reversed'
   for update;
  if not found then
    raise exception 'referral is not in a reversed state' using errcode = '22023';
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'REFERRAL_REARMED_V321', 'referrals', v_referral.id,
          jsonb_build_object('reason', btrim(p_reason),
                             'previous_reward_cents', v_referral.reward_cents,
                             'previous_reversal_sale_id', v_referral.reversed_sale_id,
                             'previous_qualified_sale_id', v_referral.qualified_sale_id));

  update public.referrals
     set status = 'pending',
         reversed_at = null,
         reversed_sale_id = null,
         qualified_at = null,
         qualified_sale_id = null,
         reward_cents = 0
   where id = v_referral.id;

  return jsonb_build_object('status','completed','referral_id',v_referral.id,
                            'status_after','pending');
end
$v319_rearm$;

comment on function public.staff_rearm_referral_v321(uuid, uuid, text) is
  'v321: returns a reversed referral to the pending pool after a mis-keyed refund. Permission '
  'refund_sales (the same permission that reversed it), reason >= 10 chars, audited as '
  'REFERRAL_REARMED_V321. Clears the qualification fields deliberately — the earn path must not '
  'be able to tell a re-armed referral from a fresh one.';

revoke all on function public.staff_rearm_referral_v321(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.staff_rearm_referral_v321(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Postconditions. Every claim this migration's header makes, asserted in-transaction.
--    XX001 on failure, so a false claim rolls the whole thing back.
-- ---------------------------------------------------------------------------

do $v319_post$
declare
  v_def text;
  v_md5 text;
  v_pin text;
  v_bad bigint;
  v_ok boolean;
  v_row record;
begin
  -- 1. The terminal state exists and its shape is machine-checked.
  --
  --    Asserted against pg_get_constraintdef rather than by attempting a bad INSERT: catching a
  --    check_violation in PL/pgSQL opens a SUBTRANSACTION, and the v313/v314 apply established
  --    that subtransactions inside a migration are a foot-gun. The BEHAVIOURAL proof that
  --    'nonsense' is refused and 'reversed' is accepted lives in the rolled-back suite, which is
  --    the right place for a write.
  select pg_get_constraintdef(c.oid) into strict v_def
    from pg_constraint c
   where c.conname = 'referrals_status_check' and c.conrelid = 'public.referrals'::regclass;
  if v_def <> 'CHECK ((status = ANY (ARRAY[''pending''::text, ''qualified''::text, ''rewarded''::text, ''reversed''::text])))' then
    raise exception 'v321: referrals_status_check is not the expected four-state check (%)', v_def
      using errcode = 'XX001';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'referrals_reversed_shape_v321'
                   and conrelid = 'public.referrals'::regclass and convalidated) then
    raise exception 'v321: referrals_reversed_shape_v321 is missing or not validated'
      using errcode = 'XX001';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'referrals_reversed_sale_same_tenant'
                   and conrelid = 'public.referrals'::regclass and contype = 'f' and convalidated) then
    raise exception 'v321: the reversed-sale same-tenant FK is missing or not validated'
      using errcode = 'XX001';
  end if;

  -- 2. RULING R-A, ASSERTED AS AN ABSENCE. The contract's shared helper was NOT built; there is
  --    no second spine writer and no function that could become one.
  if to_regprocedure('app.set_programme_active_v321(uuid,text,boolean,text)') is not null then
    raise exception 'v321: app.set_programme_active_v321 exists — ruling R-A forbids a second spine writer'
      using errcode = 'XX001';
  end if;

  -- 3. public.set_programmes_v314 is STILL the one writer of the spine, and now also writes the
  --    projection — exactly once each.
  select pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure) into strict v_def;
  if (length(v_def) - length(replace(v_def, 'update public.business_programmes spine', '')))
     / length('update public.business_programmes spine') <> 1 then
    raise exception 'v321: set_programmes_v314 no longer holds exactly one spine UPDATE' using errcode = 'XX001';
  end if;
  if (length(v_def) - length(replace(v_def, 'insert into public.referral_programs', '')))
     / length('insert into public.referral_programs') <> 1 then
    raise exception 'v321: set_programmes_v314 does not carry exactly one projection write'
      using errcode = 'XX001';
  end if;
  if position('app.c45_owner_loyalty_write' in v_def) = 0
     or position('programme_switch_operations_v314' in v_def) = 0
     or position('app.enqueue_programme_pot_migration_v312' in v_def) = 0 then
    raise exception 'v321: set_programmes_v314 lost its owner gate, receipt or pot routing'
      using errcode = 'XX001';
  end if;
  -- The projection write must come AFTER the spine UPDATE, or the trigger would compute the old
  -- value. Textual position is a proxy; suite cell 11 proves it behaviourally.
  if position('insert into public.referral_programs' in v_def)
     < position('update public.business_programmes spine' in v_def) then
    raise exception 'v321: the projection write precedes the spine UPDATE in set_programmes_v314'
      using errcode = 'XX001';
  end if;

  -- 4. public.save_referral_program writes TERMS ONLY, moves no spine row, and audits the
  --    suppressed switch.
  select pg_get_functiondef('public.save_referral_program(uuid,boolean,integer,integer)'::regprocedure)
    into strict v_def;
  if position('business_programmes' in v_def) = 0 then
    raise exception 'v321: save_referral_program does not read the spine at all' using errcode = 'XX001';
  end if;
  if position('update public.business_programmes' in v_def) > 0
     or position('insert into public.business_programmes' in v_def) > 0 then
    raise exception 'v321: save_referral_program writes the spine — ruling R-A violated'
      using errcode = 'XX001';
  end if;
  if position('enabled = excluded.enabled' in v_def) > 0 then
    raise exception 'v321: save_referral_program still projects enabled in its DO UPDATE list'
      using errcode = 'XX001';
  end if;
  if (length(v_def) - length(replace(v_def, 'REFERRAL_ENABLED_WRITE_SUPPRESSED_V321', '')))
     / length('REFERRAL_ENABLED_WRITE_SUPPRESSED_V321') <> 1 then
    raise exception 'v321: save_referral_program does not audit the suppressed switch exactly once'
      using errcode = 'XX001';
  end if;
  if position('app.can_module_write(p_business, ''referrals'')' in v_def) = 0 then
    raise exception 'v321: save_referral_program lost its manager-level module gate'
      using errcode = 'XX001';
  end if;
  if position('app.c45_owner_loyalty_write' in v_def) > 0 then
    raise exception 'v321: save_referral_program was silently narrowed to owner-only'
      using errcode = 'XX001';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'save_referral_program') <> 1 then
    raise exception 'v321: save_referral_program has more than one signature (PGRST203 risk)'
      using errcode = 'XX001';
  end if;

  -- 5. The engine gates on the SPINE, refuses $0, and refuses a zero reward.
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position('spine.kind=''referral'' and spine.active' in v_def) = 0 then
    raise exception 'v321: on_sale_recorded does not gate referral on the spine' using errcode = 'XX001';
  end if;
  if position('new.amount_cents>0' in v_def) = 0 then
    raise exception 'v321: on_sale_recorded still lets a $0 sale qualify a referral (L1 open)'
      using errcode = 'XX001';
  end if;
  if position('coalesce(refprog.reward_cents,0)>0' in v_def) = 0 then
    raise exception 'v321: on_sale_recorded lacks the zero-reward guard (till-outage shape)'
      using errcode = 'XX001';
  end if;
  if position('from public.referral_programs where business_id=new.business_id and enabled' in v_def) > 0 then
    raise exception 'v321: on_sale_recorded still gates on referral_programs.enabled (L4 open)'
      using errcode = 'XX001';
  end if;

  -- 6. The reversal is terminal, clamped, and audited.
  select pg_get_functiondef('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure)
    into strict v_def;
  if position('status = ''reversed''' in v_def) = 0 then
    raise exception 'v321: reverse_sale_v20_base does not set the terminal reversed status (L2 open)'
      using errcode = 'XX001';
  end if;
  if position('set status = ''pending''' in v_def) > 0 then
    raise exception 'v321: reverse_sale_v20_base still re-arms the referral (L2 open)'
      using errcode = 'XX001';
  end if;
  if position('-v_referral.reward_cents' in v_def) > 0 then
    raise exception 'v321: reverse_sale_v20_base still claws back the unclamped amount (L3 open)'
      using errcode = 'XX001';
  end if;
  if position('REFERRAL_CLAWBACK_SHORTFALL_V321' in v_def) = 0
     or position('referral_clawback_cents' in v_def) = 0
     or position('referral_shortfall_cents' in v_def) = 0 then
    raise exception 'v321: the clawback shortfall is not audited or not reported in the envelope'
      using errcode = 'XX001';
  end if;

  -- 7. The projection is enforced structurally, by a definer trigger with the canonical
  --    search_path and no browser reach.
  if not exists (select 1 from pg_trigger t
                  where t.tgrelid = 'public.referral_programs'::regclass
                    and t.tgname = 'trg_referral_programs_projection_v321'
                    and t.tgtype & 2 = 2                                   -- BEFORE
                    and t.tgtype & 4 = 4 and t.tgtype & 16 = 16            -- INSERT and UPDATE
                    and t.tgenabled = 'O') then
    raise exception 'v321: the referral projection trigger is missing, mistimed or disabled'
      using errcode = 'XX001';
  end if;
  for v_row in
    select p.proname, p.prosecdef, p.proconfig,
           (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute')) as browser_reachable
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname in ('referral_programs_projection_v321', 'detect_referral_gate_desync_v321')
  loop
    -- proconfig is normalised before comparison: Postgres stores `set search_path to 'a','b'` as
    -- `search_path=a, b` when the identifiers need no quoting, and the house style writes the
    -- quoted form. Strip quotes and spaces so one comparison covers both spellings.
    if not v_row.prosecdef
       or v_row.proconfig is null
       or not exists (
            select 1 from unnest(v_row.proconfig) cfg
             where replace(replace(cfg, '"', ''), ' ', '')
                   = 'search_path=pg_catalog,public,app,pg_temp') then
      raise exception 'v321: app.% is not SECURITY DEFINER with the canonical search_path (%)',
        v_row.proname, v_row.proconfig using errcode = 'XX001';
    end if;
    if v_row.browser_reachable then
      raise exception 'v321: app.% is browser-callable' , v_row.proname using errcode = '42501';
    end if;
  end loop;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app'
         and p.proname in ('referral_programs_projection_v321','detect_referral_gate_desync_v321')) <> 2 then
    raise exception 'v321: a new app function is missing' using errcode = 'XX001';
  end if;

  -- 8. The escape hatch exists, is definer, and is granted to authenticated ONLY.
  if to_regprocedure('public.staff_rearm_referral_v321(uuid,uuid,text)') is null then
    raise exception 'v321: staff_rearm_referral_v321 is missing' using errcode = 'XX001';
  end if;
  select p.prosecdef into strict v_ok from pg_proc p
   where p.oid = to_regprocedure('public.staff_rearm_referral_v321(uuid,uuid,text)');
  if not v_ok
     or has_function_privilege('anon', to_regprocedure('public.staff_rearm_referral_v321(uuid,uuid,text)'), 'execute')
     or not has_function_privilege('authenticated', to_regprocedure('public.staff_rearm_referral_v321(uuid,uuid,text)'), 'execute') then
    raise exception 'v321: staff_rearm_referral_v321 has the wrong security or grants'
      using errcode = 'XX001';
  end if;

  -- 9. THE GATE ASSERTION LIMBS ARE EMPTY. This is the invariant every later increment inherits.
  select count(*) into v_bad from app.detect_referral_gate_desync_v321()
   where reason in ('spine_vs_enabled', 'spine_on_without_row');
  if v_bad <> 0 then
    raise exception 'v321: the referral gate detector reports % assertion row(s)', v_bad
      using errcode = 'XX001';
  end if;
  for v_row in select * from app.detect_referral_gate_desync_v321()
                where reason not in ('spine_vs_enabled', 'spine_on_without_row')
  loop
    raise notice 'v321 REPORT (legal state, not a failure): % — % (reward_cents=%, module=%)',
      v_row.business_name, v_row.reason, v_row.reward_cents, v_row.module_enabled;
  end loop;

  -- 10. The two detectors that ARE assertions stay empty.
  select count(*) into v_bad from app.detect_programme_pot_split_v312();
  if v_bad <> 0 then
    raise exception 'v321: the pot-split detector moved (% rows)', v_bad using errcode = 'XX001';
  end if;
  select count(*) into v_bad from app.detect_double_earn_v309();
  if v_bad <> 0 then
    raise exception 'v321: the double-earn detector moved (% rows)', v_bad using errcode = 'XX001';
  end if;

  -- 11. RULING R-H. The spine/legacy divergence detector is READ AND REPORTED. NEVER ASSERTED.
  --     It is non-empty in production and that is V313/V314 standing invariant 5 working.
  for v_row in select * from app.detect_spine_legacy_divergence_v314() loop
    raise notice 'v321 post-apply REPORT (ruling R-H, never an assertion): % / % spine=% legacy=%',
      v_row.business_name, v_row.kind, v_row.spine_active, v_row.legacy_running;
  end loop;
  -- What v321 IS entitled to assert: referral can no longer be a divergence reason, because
  -- enabled is now a projection of the spine row.
  select count(*) into v_bad from app.detect_spine_legacy_divergence_v314() where kind = 'referral';
  if v_bad <> 0 then
    raise exception 'v321: referral still diverges from the spine after the projection (% rows)', v_bad
      using errcode = 'XX001';
  end if;

  -- 12. RULING R-G. The no-touch claims, asserted as SNAPSHOT EQUALITY against the values this
  --     migration read in its own step 0 — never against a transcribed literal.
  for v_row in
    select * from (values
      ('app.business_programmes_v307',            'app.business_programmes_v307(uuid)'),
      ('app.loyalty_ledger_write_guard',          'app.loyalty_ledger_write_guard()'),
      ('public.customer_get_referral_card_v300',  'public.customer_get_referral_card_v300(text)'),
      ('app.detect_spine_legacy_divergence_v314', 'app.detect_spine_legacy_divergence_v314()')
    ) t(key, signature)
  loop
    select value into strict v_pin from v319_pins where key = v_row.key;
    select md5(p.prosrc) into strict v_md5 from pg_proc p where p.oid = to_regprocedure(v_row.signature);
    if v_md5 <> v_pin then
      raise exception 'v321: % changed (md5 % <> step-0 snapshot %) — this migration promised not to touch it',
        v_row.key, v_md5, v_pin using errcode = 'XX001';
    end if;
  end loop;

  -- 13. The ACL of the re-bodied RPC is byte-equal to what step 0 captured, and the spine still
  --     holds four rows for every tenant.
  select value into strict v_pin from v319_pins where key = 'acl:public.save_referral_program';
  select coalesce((select string_agg(pg_get_userbyid(a.grantee)||':'||a.privilege_type, ',' order by 1)
                     from aclexplode(p.proacl) a), '')
    into strict v_md5
    from pg_proc p where p.oid = to_regprocedure('public.save_referral_program(uuid,boolean,integer,integer)');
  if v_md5 <> v_pin then
    raise exception 'v321: save_referral_program ACL moved (% <> %)', v_md5, v_pin using errcode = 'XX001';
  end if;
  select count(*) into v_bad from public.businesses b
   where (select count(*) from public.business_programmes s where s.business_id = b.id) <> 4;
  if v_bad <> 0 then
    raise exception 'v321: % business(es) do not hold exactly four spine rows', v_bad using errcode = 'XX001';
  end if;

  -- 14. v314's structural invariants survive: the seed trigger is attached, and no spine trigger
  --     is DEFERRABLE (standing invariants 4 and 6).
  if not exists (select 1 from pg_trigger where tgrelid = 'public.businesses'::regclass
                   and tgname = 'business_programmes_seed_v314') then
    raise exception 'v321: the v314 seed trigger was lost' using errcode = 'XX001';
  end if;
  if exists (select 1 from pg_trigger t
              where t.tgrelid in ('public.business_programmes'::regclass,
                                  'public.referral_programs'::regclass)
                and not t.tgisinternal and t.tgdeferrable) then
    raise exception 'v321: a spine/projection trigger is DEFERRABLE' using errcode = 'XX001';
  end if;

  -- 15. Record the post-apply md5s. v321 (stamp card kernel) is the NEXT editor of
  --     app.on_sale_recorded and v327 the one after; both must pin these values.
  raise notice 'v321 POST-APPLY PINS — app.on_sale_recorded=% public.reverse_sale_v20_base=% '
               'public.save_referral_program=% public.set_programmes_v314=%',
    (select md5(prosrc) from pg_proc where oid = to_regprocedure('app.on_sale_recorded()')),
    (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)')),
    (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.save_referral_program(uuid,boolean,integer,integer)')),
    (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.set_programmes_v314(uuid,jsonb,uuid)'));

  raise notice
    'v321 verified: the referral gate is the SPINE; referral_programs.enabled is a projection '
    'with one writer and a structural guard; $0 sales and zero-reward firms no longer pay; a '
    'reversal is terminal and its clawback is clamped and audited; the backfill was a proven '
    'no-op; the spine/legacy divergence detector was REPORTED, never asserted.';
end
$v319_post$;

commit;
