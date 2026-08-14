-- nestly_v323_stamp_quest_milestones
--
-- OWNER RULING R5, THE HALF v322 REPORTED AS BLOCKED.
-- docs/qa/evidence/V322-OWNER-PROGRAMME-RULINGS-ACCEPTANCE.md closed R5's authoring half (a
-- milestone is an ordinary catalogue reward priced in the stamps programme, the wizard authors an
-- unbounded ladder, stamp_target is derived from the last milestone) and stopped at the claim:
--
--   "stamps is like a quest - complete one set of quest (3 stamp = xx rewards, 5 stamp = xx
--    rewards, 8 stamp = xx rewards) … Milestones are non-consuming: reaching 5 does not reset
--    progress toward 8; the card keeps filling to the end of the quest."
--
-- Today app.redeem_reward_core drains points_batches FEFO and appends a negative points_ledger row
-- for cost_points, so claiming the 3-stamp prize SPENDS three stamps and pushes the 5-stamp prize
-- three further away. That is the one remaining gap and it is what this migration closes.
--
-- ---------------------------------------------------------------------------------------------
-- THE MODEL, STATED ONCE.
--
--   A CARD IS A PROJECTION, NOT A STORED BALANCE.
--       net_stamps   := sum(points_ledger.points) on the stamps programme  (ALL entry types)
--       closed_slots := sum(stamp_cycles.slots)   for (business, client, stamps programme)
--       filled       := greatest(net_stamps - closed_slots, 0)
--       cycle_index  := count(stamp_cycles rows)                            -- 0-based, monotone
--       slots (N)    := loyalty_programs.stamp_target                       -- NULL = not configured
--   A CYCLE IS RECORDED ONLY WHEN IT CLOSES, and it closes when the FINAL milestone of the quest
--   is claimed. Nothing is written on the earn path; app.on_sale_recorded is not touched at all.
--
--   A CLAIM IS NON-CONSUMING, LITERALLY. No points_ledger row, no points_batches update, no
--   loyalty_redemption_batch_drains row. The stamps ledger stays a pure lifetime accrual record.
--   Claiming the 3-stamp milestone therefore leaves `filled` exactly where it was, and the
--   5-stamp milestone is still two stamps away. That is R5.
--
--   THE FINAL CLAIM IS WHERE THE STAMPS ARE CONSUMED, exactly once, and it consumes them by
--   RECORDING THE CYCLE, not by moving the ledger. One stamp_cycles row with slots = N raises
--   closed_slots by N, so filled falls by exactly N and the remainder carries into the next card.
--   Idempotent by construction: stamp_cycles_cycle_uk (business, client, programme, cycle_index)
--   and stamp_cycles_redemption_uk (redemption_id) each make a second closure impossible, and the
--   loyalty_operations idempotency above them replays the stored result without re-entering.
--
--   WHY NOT A LEDGER DEBIT AT CLOSURE. A -N points_ledger row would subtract N from net_stamps
--   while the cycle row subtracts N again from the projection — the card would lose 2N. Choosing
--   the projection over the ledger also keeps every W5 invariant intact: sum(remaining) still
--   equals sum(points) on the stamps pot, so app.programme_balance_scope_v312 stays
--   'programme_pot' and app.detect_programme_pot_split_v312 stays empty.
--
--   THE SCARCE RESOURCE IS NO LONGER A BALANCE. It is two unique indexes on
--   public.stamp_milestone_claims: one per (client, cycle, slot) — the product rule, one gift per
--   milestone per card — and one per (client, cycle, reward) — the idempotency key, so moving a
--   gift from slot 5 to slot 7 mid-cycle cannot be claimed twice on one card.
--
-- ---------------------------------------------------------------------------------------------
-- THE MONEY-KERNEL CHANGE, AND WHY IT MAKES THE INVARIANT STRONGER RATHER THAN WEAKER.
--
-- Owner-authorised. public.loyalty_redemptions.points_spent relaxes from CHECK (> 0) to (>= 0) and
-- public.loyalty_redemption_provenance.points_ledger_id becomes nullable — BOTH PAIRED with a new
-- consumes_balance boolean NOT NULL DEFAULT true and same-row CHECKs binding them:
--
--     loyalty_redemptions:            (consumes_balance and points_spent > 0)
--                                  or (not consumes_balance and points_spent = 0)
--     loyalty_redemption_provenance:  (consumes_balance and points_ledger_id is not null)
--                                  or (not consumes_balance and points_ledger_id is null)
--
-- Today "points_spent > 0" silently does double duty as "money moved". Afterwards that meaning is
-- EXPLICIT, machine-checked, and defaults to true — so an ordinary POINTS reward is structurally
-- unable to record a free claim, which is strictly more than the old CHECK guaranteed. The suite
-- proves it directly (cell 21: insert points_spent=0, consumes_balance=true -> check_violation).
--
-- WHY THE CLAIM STAYS IN loyalty_redemptions AT ALL. The honest alternative — record stamp claims
-- only in stamp_milestone_claims — needs no money-table change, and costs: stamp gifts vanish from
-- Customer 360's redemption history, from public.business_programme_usage_v271, from per-customer
-- usage_limit enforcement (which counts loyalty_redemptions rows), and from the QR path entirely,
-- because public.merchant_scan_redemption_qr_v117 raises 40001 'canonical catalog redemption was
-- not recorded' when the provenance row for the operation is absent. THAT PATH IS HANDLED
-- EXPLICITLY HERE: a stamp claim still writes its provenance row, with points_ledger_id NULL, and
-- v117 selects only provenance.redemption_id — so v117 needs no change and is deliberately kept
-- out of this migration's md5 chain. Post-assertion 11.7 proves its body is byte-identical.
--
-- ---------------------------------------------------------------------------------------------
-- WHAT IS NOT TOUCHED, AND IS ASSERTED SO RATHER THAN PROMISED (post-assertion 11.6).
--   · app.on_sale_recorded — the W5 earn loop, its (sale, programme) arbiter
--     (points_earn_once_per_sale_per_programme) and the in-trigger ledger/batch parity assertion.
--     md5(prosrc) is pinned before and compared after. Stamps still earns into its own programme
--     pot and still writes its batch rows, which are simply never drained.
--   · app.enqueue_programme_pot_migration_v312 and public.set_programmes_v314.
--   · app.detect_double_earn_v309 and app.detect_programme_pot_split_v312 — both re-run and
--     required empty.
--   · app.run_points_expiry_for_business — already filters pb.programme_id = the points programme,
--     so stamp batches are structurally unsweepable. No guard needed and none added.
--
-- A POINTS REWARD'S BEHAVIOUR IS BYTE-IDENTICAL AFTERWARDS. Every needle into
-- app.redeem_reward_core either (a) adds a declaration, (b) adds an `if v_programme_kind='stamps'`
-- arm whose ELSE is the live statement verbatim, or (c) substitutes v_points_spent for
-- v_version.cost_points, where v_points_spent is assigned v_version.cost_points on the points arm.
-- The FEFO loop, the batch drains, the redeem ledger row, the credit arm, the operation
-- idempotency, the eligibility gates, the v176 tier gate and the usage_limit count are unchanged.
-- Suite cells 19/20 execute a points claim end to end and compare every row it writes.
--
-- ---------------------------------------------------------------------------------------------
-- CONCURRENCY. Two counter scans at the same moment cannot double-claim a milestone or close a
-- cycle twice, for three independent reasons and in that order:
--   1. app.redeem_reward_core already takes `perform 1 from public.clients c where c.id=p_client
--      and c.business_id=p_business for update` before it reads any balance. Every key in this
--      migration is per (business, client), so two claims for one customer SERIALISE on that row
--      lock — the second reads app.stamp_progress_v323 only after the first has committed its
--      cycle row. This is the money kernel's own row-lock discipline; no advisory lock is added.
--   2. loyalty_operations (business_id, operation_type, idempotency_key) with `for update` and the
--      stored-result replay already collapses a retried scan of the same QR.
--   3. Even if 1 and 2 were bypassed, the two unique indexes on stamp_milestone_claims and the two
--      on stamp_cycles turn the race into a 23505 with an owner-readable sentence rather than a
--      second gift. db/tests/v323_stamp_quest_concurrency.sh drives two real sessions at it.
--
-- ---------------------------------------------------------------------------------------------
-- PRODUCTION SHAPE AT WRITE TIME (read live, read-only, from gadpooereceldfpfxsod): ZERO firms run
-- the stamps programme, ZERO stamps rewards are active, stamp_target is NULL on every row, and
-- neither new table exists. Production green therefore proves ABSENCE OF REGRESSION, not presence
-- of correctness — so db/tests/v323_stamp_quest_milestones.sql constructs every tenant shape it
-- exercises inside its own rolled-back transaction.
--
-- MONEY SCOPE. This migration writes no credit_ledger row, no points_ledger row, no points_batches
-- row, no sale, no stamp_cycles row and no stamp_milestone_claims row. It adds two tables, three
-- columns, one unique constraint, two functions, and fourteen counted needles across five bodies.
--
-- ROLLBACK, SAID OUT LOUD. Re-splice the five bodies back to the old_text preserved verbatim in
-- this file; drop public.customer_get_stamp_card_v323 and app.stamp_progress_v323; drop the two
-- tables; drop the two shape CHECKs and the two consumes_balance columns and restore
-- loyalty_redemptions_points_spent_check to (> 0) and provenance.points_ledger_id to NOT NULL.
-- The restore of those two is only possible while no non-consuming row exists, so a rollback after
-- a stamps firm has claimed a milestone is a data decision, not a DDL one. Said here, not in an
-- incident.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition. Same prelude, same reason, as v313/v314
-- and v322: everything contested is taken up front in one ordered acquisition
-- so no cycle can form. storage.objects is conditional because rigs replay
-- app/public only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v323_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v323_prelock$;

lock table public.businesses, public.business_programmes, public.loyalty_redemptions,
           public.loyalty_redemption_provenance, public.loyalty_programs
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- 0. Predecessor pins and preconditions. Fail closed.
--
-- Every md5 below was READ LIVE from gadpooereceldfpfxsod through the read-only
-- MCP server on 2026-08-14, AFTER v322 was applied (schema_migrations holds
-- 20260814000300 nestly_v322_owner_programme_rulings). None was transcribed
-- from an evidence document. They are raw md5(prosrc): none of these bodies
-- carries a full-line comment that a production apply would strip, except
-- customer_get_reward_catalog and customer_get_business_actions_v89, whose
-- comments are already present in the live prosrc and are therefore part of the
-- hash exactly as read.
-- ---------------------------------------------------------------------------

do $v323_pins$
declare
  v_md5 text;
  v_count bigint;
begin
  -- (a) The already-applied guard.
  if to_regclass('public.stamp_cycles') is not null
     or to_regprocedure('app.stamp_progress_v323(uuid,uuid)') is not null then
    raise exception 'v323 is already applied (stamp_cycles or app.stamp_progress_v323 exists)'
      using errcode = '23514';
  end if;

  -- (b) THE PIN TABLE.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if v_md5 <> '37ae059cca6715bd998daab843776279' then
    raise exception 'v323: app.redeem_reward_core is not the expected predecessor body (md5=%)',
      v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_create_redemption_intent_v89';
  if v_md5 <> '2913f3847db0a5c77427cbcc5edc7b0f' then
    raise exception 'v323: public.customer_create_redemption_intent_v89 is not the expected '
      'predecessor body (md5=%)', v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if v_md5 <> '07897b24b70da71c5a954d748cc0df3d' then
    raise exception 'v323: public.customer_get_reward_catalog is not the expected predecessor '
      'body (md5=%)', v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_actions_v89';
  if v_md5 <> '7cce57c72be68556a54784ce0020aff9' then
    raise exception 'v323: public.customer_get_business_actions_v89 is not the expected '
      'predecessor body (md5=%)', v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';
  if v_md5 <> '6bcc491a86d0f19a7284dc6deda83097' then
    raise exception 'v323: public.publish_loyalty_config is not the expected predecessor body '
      '(md5=%)', v_md5 using errcode = '23514';
  end if;

  -- The two bodies this migration must NOT change. Pinned here and re-compared
  -- in section 11, so "untouched" is asserted at both ends.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_md5 <> '7885f43285cb9584e500e959311d4feb' then
    raise exception 'v323: app.on_sale_recorded is not the v322 post-state body (md5=%); this '
      'migration pins it as UNTOUCHED and cannot prove that against an unknown body', v_md5
      using errcode = '23514';
  end if;
  perform set_config('v323.on_sale_recorded_md5', v_md5, true);

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'merchant_scan_redemption_qr_v117';
  if v_md5 <> 'e6117b02a0746f8e87cf0f5eda5b71f5' then
    raise exception 'v323: public.merchant_scan_redemption_qr_v117 is not the expected body '
      '(md5=%); this migration pins it as UNTOUCHED', v_md5 using errcode = '23514';
  end if;
  perform set_config('v323.v117_md5', v_md5, true);

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_programmes_v314';
  perform set_config('v323.set_programmes_md5', v_md5, true);
  raise notice 'v323: public.set_programmes_v314 pinned as untouched at md5=%', v_md5;

  -- (c) The two money invariants this migration relaxes must be in the shape it
  --     expects, or the relaxation is being applied over something else.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.loyalty_redemptions'::regclass
                    and conname = 'loyalty_redemptions_points_spent_check'
                    and pg_get_constraintdef(oid) = 'CHECK ((points_spent > 0))') then
    raise exception 'v323: loyalty_redemptions_points_spent_check is not CHECK ((points_spent > 0))'
      using errcode = '23514';
  end if;
  if exists (select 1 from pg_attribute
              where attrelid = 'public.loyalty_redemption_provenance'::regclass
                and attname = 'points_ledger_id' and not attnotnull) then
    raise exception 'v323: loyalty_redemption_provenance.points_ledger_id is already nullable'
      using errcode = '23514';
  end if;

  -- (d) No provenance row may already be missing its ledger id. The relaxation
  --     must not be able to be mistaken later for having weakened a legacy row.
  select count(*) into strict v_count
    from public.loyalty_redemption_provenance where points_ledger_id is null;
  if v_count <> 0 then
    raise exception 'v323: % provenance row(s) already have a null points_ledger_id', v_count
      using errcode = '23514';
  end if;

  select count(*) into strict v_count from public.loyalty_redemptions where points_spent <= 0;
  if v_count <> 0 then
    raise exception 'v323: % redemption(s) already record points_spent <= 0', v_count
      using errcode = '23514';
  end if;

  raise notice 'v323: pins met; both money invariants are in their pre-v323 shape and no row '
    'anticipates the relaxation.';
end
$v323_pins$;

-- ---------------------------------------------------------------------------
-- 1. The composite unique the spine needs.
--
-- public.business_programmes carries pkey (id) and unique (business_id, kind)
-- but no unique (id, business_id), so the house's standard tenant-safe
-- composite FK — the shape every other table in this area uses — is impossible
-- against it. Purely additive: no behaviour change, no impact on
-- public.set_programmes_v314, and it is the reason the two new tables cannot
-- reference another tenant's programme row even if a caller tried.
-- ---------------------------------------------------------------------------

alter table public.business_programmes
  add constraint business_programmes_id_business_uk unique (id, business_id);

-- ---------------------------------------------------------------------------
-- 2. The money-kernel change (owner-authorised; see the header).
--
-- ADD COLUMN ... NOT NULL DEFAULT true is DDL: it fires no row trigger, so
-- app.loyalty_redemption_immutable_guard and app.v34_immutable_evidence_guard
-- are not invoked, and on PostgreSQL 11+ the default is stored as a
-- pg_attribute missing-value with no table rewrite. THERE MUST BE NO BACKFILL
-- UPDATE ANYWHERE IN THIS FILE — it would raise restrict_violation on every
-- existing row. Post-assertion 11.3 proves the fast default reached every row
-- without one.
-- ---------------------------------------------------------------------------

alter table public.loyalty_redemptions
  add column consumes_balance boolean not null default true;
alter table public.loyalty_redemption_provenance
  add column consumes_balance boolean not null default true;

alter table public.loyalty_redemptions drop constraint loyalty_redemptions_points_spent_check;
alter table public.loyalty_redemptions
  add constraint loyalty_redemptions_points_spent_check check (points_spent >= 0),
  add constraint loyalty_redemptions_consumption_shape_check check (
       (consumes_balance and points_spent > 0)
    or (not consumes_balance and points_spent = 0));

alter table public.loyalty_redemption_provenance alter column points_ledger_id drop not null;
alter table public.loyalty_redemption_provenance
  add constraint loyalty_redemption_provenance_consumption_shape_check check (
       (consumes_balance and points_ledger_id is not null)
    or (not consumes_balance and points_ledger_id is null));

comment on column public.loyalty_redemptions.consumes_balance is
  'v323: did this redemption take a balance? true for every points reward — the paired CHECK then '
  'requires points_spent > 0, so an ordinary points reward is structurally unable to record a free '
  'claim. false only for a stamp-quest milestone claim, which is non-consuming by design (R5): no '
  'points_ledger row, no points_batches drain, points_spent = 0.';
comment on column public.loyalty_redemption_provenance.consumes_balance is
  'v323: the same flag, denormalised so the provenance row''s own CHECK can bind it to '
  'points_ledger_id. true => a ledger row exists; false => there is none, because nothing moved. '
  'public.merchant_scan_redemption_qr_v117 reads only redemption_id and is unaffected.';

-- ---------------------------------------------------------------------------
-- 3. public.stamp_cycles — a completed card.
--
-- One row per CLOSED card. Recorded at the FINAL CLAIM, never at earn time, so
-- app.on_sale_recorded gains no writer and progress stays a pure STABLE read.
--
-- slots is the N IN FORCE AT CLOSURE, stored rather than derived. An owner may
-- edit stamp_target; deriving cycles as floor(net/N) would rewrite every
-- historical boundary the moment they did, and a customer holding a completed
-- card would lose it. Storing N makes history immutable and moves only the
-- CURRENT card's target — which is the intuitive behaviour: 8 -> 10 with a
-- customer at 9 means "9 of 10, one short", not "you already had a card".
-- ---------------------------------------------------------------------------

create table public.stamp_cycles (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  programme_id      uuid not null,
  client_id         uuid not null,
  cycle_index       integer not null,
  slots             integer not null,
  closed_at         timestamptz not null default now(),
  origin            text not null default 'claimed',
  redemption_id     uuid,
  reward_id         uuid,
  config_version_id uuid,
  actor             uuid,
  constraint stamp_cycles_cycle_index_check check (cycle_index >= 0),
  constraint stamp_cycles_slots_check       check (slots > 0),
  constraint stamp_cycles_origin_check      check (origin in ('claimed','migration')),
  constraint stamp_cycles_shape_check check (
       (origin = 'claimed'   and redemption_id is not null and reward_id is not null
                             and config_version_id is not null)
    or (origin = 'migration' and redemption_id is null     and reward_id is null)),
  constraint stamp_cycles_programme_fk foreign key (programme_id, business_id)
    references public.business_programmes(id, business_id) on delete restrict,
  constraint stamp_cycles_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint stamp_cycles_redemption_fk foreign key (redemption_id, business_id)
    references public.loyalty_redemptions(id, business_id) on delete restrict,
  constraint stamp_cycles_reward_fk foreign key (reward_id, business_id)
    references public.loyalty_rewards(id, business_id) on delete restrict,
  constraint stamp_cycles_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint stamp_cycles_id_business_uk unique (id, business_id),
  constraint stamp_cycles_cycle_uk unique (business_id, client_id, programme_id, cycle_index),
  constraint stamp_cycles_redemption_uk unique (redemption_id)
);

create index stamp_cycles_client_idx
  on public.stamp_cycles (business_id, client_id, programme_id);

comment on table public.stamp_cycles is
  'v323 (owner ruling R5): one row per COMPLETED stamp card. Written only when the FINAL milestone '
  'of the quest is claimed. sum(slots) is what the card projection subtracts from the lifetime '
  'stamp count, so recording a cycle IS how a quest''s stamps are consumed — exactly once, and '
  'without moving the append-only ledger.';
comment on column public.stamp_cycles.slots is
  'v323: the N in force AT CLOSURE. Stored, not derived, so editing stamp_target never rewrites a '
  'card the customer already completed.';

-- ---------------------------------------------------------------------------
-- 4. public.stamp_milestone_claims — one gift per milestone per card.
--
-- TWO unique indexes, deliberately, because they close two different holes:
--   · _slot_uk  is the PRODUCT RULE — one gift per milestone per card. It also
--     closes "the owner swaps the gift at slot 5 mid-cycle and the customer
--     claims both".
--   · _reward_uk is the IDEMPOTENCY KEY — the same gift cannot be claimed twice
--     on one card even if the owner MOVES it from slot 5 to slot 7 mid-cycle.
-- Two gifts authored at the same slot are legal to create but only one is
-- claimable per cycle. That is the correct product rule; the owner surface says
-- so in words.
--
-- cycle_index is part of BOTH keys, which is what makes a milestone claimable
-- AGAIN on the next card. Drop it from either and the quest becomes once-ever.
-- ---------------------------------------------------------------------------

create table public.stamp_milestone_claims (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete cascade,
  programme_id       uuid not null,
  client_id          uuid not null,
  cycle_index        integer not null,
  slot_position      integer not null,
  reward_id          uuid not null,
  reward_version_id  uuid not null,
  redemption_id      uuid not null,
  config_version_id  uuid not null,
  is_final           boolean not null,
  claimed_at         timestamptz not null default now(),
  actor              uuid,
  constraint stamp_milestone_claims_cycle_index_check check (cycle_index >= 0),
  constraint stamp_milestone_claims_slot_check        check (slot_position > 0),
  constraint stamp_milestone_claims_programme_fk foreign key (programme_id, business_id)
    references public.business_programmes(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_reward_fk foreign key (reward_id, business_id)
    references public.loyalty_rewards(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_version_fk foreign key (reward_version_id, business_id)
    references public.loyalty_reward_versions(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_redemption_fk foreign key (redemption_id, business_id)
    references public.loyalty_redemptions(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint stamp_milestone_claims_slot_uk
    unique (business_id, client_id, programme_id, cycle_index, slot_position),
  constraint stamp_milestone_claims_reward_uk
    unique (business_id, client_id, programme_id, cycle_index, reward_id),
  constraint stamp_milestone_claims_redemption_uk unique (redemption_id)
);

comment on table public.stamp_milestone_claims is
  'v323 (owner ruling R5): the per (client, quest cycle, milestone) claim record. Claiming a '
  'non-final milestone writes ONE of these and consumes nothing — no ledger row, no batch drain — '
  'so reaching 3 stamps never pushes the 5-stamp milestone further away.';

-- Append-only, the same guard public.loyalty_redemption_provenance and
-- public.loyalty_redemption_batch_drains already carry.
create trigger trg_stamp_cycles_immutable
  before delete or update on public.stamp_cycles
  for each row execute function app.v34_immutable_evidence_guard();
create trigger trg_stamp_milestone_claims_immutable
  before delete or update on public.stamp_milestone_claims
  for each row execute function app.v34_immutable_evidence_guard();

alter table public.stamp_cycles            enable row level security;
alter table public.stamp_milestone_claims  enable row level security;

create policy stamp_cycles_read on public.stamp_cycles
  for select using (app.is_salon_member(business_id));
create policy stamp_cycles_sa_read on public.stamp_cycles
  for select using (app.is_super_admin());
create policy stamp_milestone_claims_read on public.stamp_milestone_claims
  for select using (app.is_salon_member(business_id));
create policy stamp_milestone_claims_sa_read on public.stamp_milestone_claims
  for select using (app.is_super_admin());
-- NO write policy on either table, deliberately. Every write is SECURITY DEFINER
-- through app.redeem_reward_core; there is no other route and there must not be.

-- Schema public carries a Supabase DEFAULT ACL granting arwdDxtm (ALL) to BOTH anon and
-- authenticated on every new table, so revoking from `public, anon` leaves authenticated able to
-- INSERT/UPDATE/DELETE these evidence tables. Name authenticated too, then grant back only SELECT
-- — the shape public.programme_switch_operations_v314 already has. The grant floor below caught
-- exactly this on the first apply attempt.
revoke all on public.stamp_cycles           from public, anon, authenticated;
revoke all on public.stamp_milestone_claims from public, anon, authenticated;
grant select on public.stamp_cycles           to authenticated;
grant select on public.stamp_milestone_claims to authenticated;
grant all    on public.stamp_cycles           to service_role, postgres;
grant all    on public.stamp_milestone_claims to service_role, postgres;

-- ---------------------------------------------------------------------------
-- 5. app.stamp_progress_v323 — the projection, and the only place it is stated.
--
-- STABLE and writes nothing, which is what closure-at-claim buys: it is safe to
-- call from public.customer_get_reward_catalog, which is STABLE and cannot call
-- a writer. RETURNS ZERO ROWS when the firm has no stamps spine row; every
-- caller checks `if not found`.
--
-- net_stamps is sum(points) over ALL entry types on the stamps programme, not
-- just 'earn'. The stamps pot can legitimately carry 'adjust' rows from a v84
-- sale-amount correction, a redemption reversal, or a programme_pot_transfer,
-- and a card computed from earns alone would silently disagree with the pot the
-- W5 detectors police.
--
-- filled is CLAMPED at zero. If an owner switches stamps off and points on,
-- public.set_programmes_v314 enqueues a pot migration and the stamp pot MOVES:
-- net_stamps goes to zero (the transfer writes an offsetting adjust on the FROM
-- programme) while stamp_cycles still holds the closed cards, so the raw
-- difference goes negative. pot_migrated reports that state so the customer
-- surface can say what happened instead of printing a misleading 0/8.
-- ---------------------------------------------------------------------------

create or replace function app.stamp_progress_v323(p_business uuid, p_client uuid)
returns table(programme_id uuid, programme_active boolean, running_since timestamptz,
              paused_since timestamptz, slots integer, net_stamps integer,
              closed_slots integer, filled integer, cycle_index integer,
              ready boolean, pot_migrated boolean)
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select spine.id,
         spine.active,
         spine.activated_at,
         spine.deactivated_at,
         target.stamp_target,
         coalesce(led.net, 0)::integer,
         coalesce(cyc.closed, 0)::integer,
         greatest(coalesce(led.net, 0) - coalesce(cyc.closed, 0), 0)::integer,
         coalesce(cyc.cycles, 0)::integer,
         target.stamp_target is not null
           and target.stamp_target > 0
           and greatest(coalesce(led.net, 0) - coalesce(cyc.closed, 0), 0) >= target.stamp_target,
         exists (select 1 from public.programme_pot_migrations m
                  where m.business_id = p_business and m.from_programme_id = spine.id)
    from public.business_programmes spine
    cross join lateral (
      select (select prog.stamp_target from public.loyalty_programs prog
               where prog.business_id = p_business order by prog.id limit 1) as stamp_target
    ) target
    left join lateral (
      select coalesce(sum(pl.points), 0) as net
        from public.points_ledger pl
       where pl.business_id = p_business and pl.client_id = p_client
         and pl.programme_id = spine.id
    ) led on true
    left join lateral (
      select coalesce(sum(sc.slots), 0) as closed, count(*)::integer as cycles
        from public.stamp_cycles sc
       where sc.business_id = p_business and sc.client_id = p_client
         and sc.programme_id = spine.id
    ) cyc on true
   where spine.business_id = p_business and spine.kind = 'stamps'
$$;

revoke all privileges on function app.stamp_progress_v323(uuid,uuid)
  from public, anon, authenticated;

comment on function app.stamp_progress_v323(uuid,uuid) is
  'v323 (R5): the stamp CARD, computed rather than stored. filled = lifetime stamps on the stamps '
  'programme minus the slots of every CLOSED cycle, clamped at zero. Zero rows when the firm has '
  'no stamps programme. Internal: nothing browser-reachable may call it directly.';

-- ---------------------------------------------------------------------------
-- 6 .. 10. The needles. Every occurrence count is asserted before the replace,
-- and every old_text is preserved verbatim in this file as the rollback image.
--
--  6  app.redeem_reward_core                        6 needles  (the claim itself)
--  7  public.customer_create_redemption_intent_v89  2 needles  (the QR mint gate)
--  8  public.customer_get_reward_catalog            3 needles  (customer availability)
--  9  public.customer_get_business_actions_v89      3 needles  (the scannable list)
-- 10  public.publish_loyalty_config                 1 needle   (the closure guard)
--
-- WHY 10 IS HERE AND IS A REFUSAL, NOT A WARNING. Under closure-at-claim, a live
-- stamp card with no gift at exactly stamp_target CAN NEVER RESET: it fills to
-- N/N, says Ready for ever, and the customer's stamps pile up behind a door with
-- no handle. That is the same class of broken state the existing
-- `stamp_per_cents <= 0` refusal already forbids, and it fires only when the
-- stamps switch is already ON — of which production has zero. The v322 wizard
-- DERIVES stamp_target from the last milestone, so an owner using the shipped
-- surface can never meet it; it exists for every other door.
-- ---------------------------------------------------------------------------

do $v323_needles$
declare
  v_def text;
  v_o integer;
  v_n integer;
  v_target record;
begin
  for v_target in
    select * from (values

      -- ================= 6. app.redeem_reward_core =================

      -- 6.1 declarations
      (1, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  v_usage integer; v_eligibility jsonb; v_result json; v_reward_programme uuid;$needle$,
       $needle$  v_usage integer; v_eligibility jsonb; v_result json; v_reward_programme uuid;
  v_programme_kind text; v_stamp_slots integer; v_stamp_filled integer; v_cycle_index integer;
  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid;$needle$),

      -- 6.2 capture the programme kind, right after the spine-active refusal
      (2, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;$needle$,
       $needle$  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;
  select spine.kind into v_programme_kind from public.business_programmes spine where spine.id=v_reward_programme;$needle$),

      -- 6.3 the affordability test. The ELSE arm is the live pair VERBATIM, so a
      --     points reward asks exactly the question it asked before.
      (3, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;
  if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;$needle$,
       $needle$  if v_programme_kind='stamps' then
    v_consumes:=false; v_points_spent:=0;
    select sp.slots,sp.filled,sp.cycle_index into v_stamp_slots,v_stamp_filled,v_cycle_index from app.stamp_progress_v323(p_business,p_client) sp;
    if not found then raise exception 'this business is not running a stamp card' using errcode='XX001'; end if;
    if coalesce(v_stamp_slots,0)<=0 then raise exception 'this stamp card has no length set' using errcode='23514'; end if;
    if v_version.cost_points>v_stamp_slots then raise exception 'this gift sits past the end of the stamp card' using errcode='23514'; end if;
    if v_stamp_filled<v_version.cost_points then raise exception 'not enough stamps yet' using errcode='check_violation'; end if;
  else
    v_points_spent:=v_version.cost_points;
    select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;
    if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;
  end if;$needle$),

      -- 6.4 both evidence inserts learn consumes_balance. points_spent becomes
      --     v_points_spent, which IS v_version.cost_points on the points arm.
      (4, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  insert into public.loyalty_redemptions(id,business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number)
  values(v_redemption_id,p_business,p_client,p_reward,v_version.customer_name,v_version.cost_points,v_version.credit_cents,v_actor,v_version.id,
    to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
    case when v_version.entitlement_expiry_days is null then null else now()+make_interval(days=>v_version.entitlement_expiry_days) end,v_usage+1);
  insert into public.loyalty_redemption_provenance
    (id,business_id,client_id,operation_id,redemption_id,points_ledger_id,credit_ledger_id,config_version_id)
  values(v_provenance_id,p_business,p_client,v_operation_id,v_redemption_id,v_points_id,
    case when v_version.credit_cents>0 then gen_random_uuid() end,v_version.config_version_id)
  returning credit_ledger_id into v_credit_id;$needle$,
       $needle$  insert into public.loyalty_redemptions(id,business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number,consumes_balance)
  values(v_redemption_id,p_business,p_client,p_reward,v_version.customer_name,v_points_spent,v_version.credit_cents,v_actor,v_version.id,
    to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
    case when v_version.entitlement_expiry_days is null then null else now()+make_interval(days=>v_version.entitlement_expiry_days) end,v_usage+1,v_consumes);
  insert into public.loyalty_redemption_provenance
    (id,business_id,client_id,operation_id,redemption_id,points_ledger_id,credit_ledger_id,config_version_id,consumes_balance)
  values(v_provenance_id,p_business,p_client,v_operation_id,v_redemption_id,case when v_consumes then v_points_id end,
    case when v_version.credit_cents>0 then gen_random_uuid() end,v_version.config_version_id,v_consumes)
  returning credit_ledger_id into v_credit_id;$needle$),

      -- 6.5 THE RULING. The whole FEFO drain and the redeem ledger row are moved
      --     VERBATIM under `if v_consumes then`; the else arm writes the claim
      --     and, when the milestone is the last one, closes the cycle. The
      --     credit arm below this block is deliberately left OUTSIDE the branch:
      --     a credit-kind stamp gift still pays its credit exactly as before.
      (5, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining);
    update public.points_batches set remaining=remaining-v_take where id=v_batch.id;
    insert into public.loyalty_redemption_batch_drains
      (provenance_id,business_id,client_id,redemption_id,points_batch_id,drained_points)
    values(v_provenance_id,p_business,p_client,v_redemption_id,v_batch.id,v_take);
    v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);$needle$,
       $needle$  if v_consumes then
  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining);
    update public.points_batches set remaining=remaining-v_take where id=v_batch.id;
    insert into public.loyalty_redemption_batch_drains
      (provenance_id,business_id,client_id,redemption_id,points_batch_id,drained_points)
    values(v_provenance_id,p_business,p_client,v_redemption_id,v_batch.id,v_take);
    v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  else
    begin
      insert into public.stamp_milestone_claims(
        business_id,programme_id,client_id,cycle_index,slot_position,reward_id,reward_version_id,
        redemption_id,config_version_id,is_final,actor)
      values(p_business,v_reward_programme,p_client,v_cycle_index,v_version.cost_points,p_reward,
        v_version.id,v_redemption_id,v_version.config_version_id,v_version.cost_points>=v_stamp_slots,v_actor);
      if v_version.cost_points>=v_stamp_slots then
        v_cycle_id:=gen_random_uuid();
        insert into public.stamp_cycles(
          id,business_id,programme_id,client_id,cycle_index,slots,origin,redemption_id,reward_id,
          config_version_id,actor)
        values(v_cycle_id,p_business,v_reward_programme,p_client,v_cycle_index,v_stamp_slots,'claimed',
          v_redemption_id,p_reward,v_version.config_version_id,v_actor);
      end if;
    exception when unique_violation then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23505';
    end;
  end if;$needle$),

      -- 6.6 the result envelope. points_spent becomes the truth (0 for a stamp
      --     claim); four additive keys carry the quest facts to the counter and
      --     to public.merchant_scan_redemption_qr_v117's nested `result` object.
      (6, 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       $needle$  v_result:=json_build_object('ok',true,'redemption_id',v_redemption_id,
    'reward_version_id',v_version.id,'reward',v_version.customer_name,
    'points_spent',v_version.cost_points,'credit_cents',v_version.credit_cents);$needle$,
       $needle$  v_result:=json_build_object('ok',true,'redemption_id',v_redemption_id,
    'reward_version_id',v_version.id,'reward',v_version.customer_name,
    'points_spent',v_points_spent,'credit_cents',v_version.credit_cents,
    'consumes_balance',v_consumes,
    'stamp_slot',case when v_programme_kind='stamps' then v_version.cost_points end,
    'stamp_cycle_index',v_cycle_index,'stamp_card_closed',v_cycle_id is not null);$needle$),

      -- ========== 7. public.customer_create_redemption_intent_v89 ==========
      -- An intent that cannot settle must never mint a QR. Without this, a
      -- customer whose stamps are all behind a closed cycle, or who already
      -- claimed this milestone on this card, gets a QR that dies at the counter.

      (7, 'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
       $needle$  v_intent_programme uuid;
begin$needle$,
       $needle$  v_intent_programme uuid;
  v_intent_programme_kind text;
  v_stamp_filled integer;
  v_stamp_cycle integer;
begin$needle$),

      (8, 'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)',
       $needle$  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
  if least(v_balance,v_batch_balance)<v_cost_points then
    raise exception 'insufficient points' using errcode='23514';
  end if;$needle$,
       $needle$  select spine.kind into v_intent_programme_kind from public.business_programmes spine
   where spine.id=v_intent_programme;
  if v_intent_programme_kind='stamps' then
    select sp.filled,sp.cycle_index into v_stamp_filled,v_stamp_cycle
      from app.stamp_progress_v323(p_business,v_client) sp;
    if not found then
      raise exception 'this business is not running a stamp card' using errcode='23514';
    end if;
    if coalesce(v_stamp_filled,0)<v_cost_points then
      raise exception 'not enough stamps yet' using errcode='23514';
    end if;
    if exists(select 1 from public.stamp_milestone_claims claim
               where claim.business_id=p_business and claim.client_id=v_client
                 and claim.programme_id=v_intent_programme
                 and claim.cycle_index=v_stamp_cycle
                 and (claim.slot_position=v_cost_points or claim.reward_id=p_reward)) then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23514';
    end if;
  else
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
  if least(v_balance,v_batch_balance)<v_cost_points then
    raise exception 'insufficient points' using errcode='23514';
  end if;
  end if;$needle$),

      -- ============= 8. public.customer_get_reward_catalog =============
      -- The customer's own availability words. A milestone already claimed on
      -- this card reports 'limit_reached' — the EXISTING vocabulary, chosen
      -- deliberately over a new value so the shared client map at
      -- app/app.js is untouched and an old cached bundle cannot meet a status
      -- it has no word for. Its rendered sentence, "Claim limit reached", is
      -- true: on this card, it is.

      (9, 'public.customer_get_reward_catalog(text)',
       $needle$  v_result jsonb;
  v_balance_scope text;
begin$needle$,
       $needle$  v_result jsonb;
  v_balance_scope text;
  v_stamps_programme uuid;
  v_stamp_filled integer;
  v_stamp_cycle integer;
begin$needle$),

      (10, 'public.customer_get_reward_catalog(text)',
       $needle$  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);$needle$,
       $needle$  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);

  select spine.id into v_stamps_programme
    from public.business_programmes spine
   where spine.business_id = v_context.business_id and spine.kind = 'stamps';
  select coalesce(sp.filled, 0), coalesce(sp.cycle_index, 0)
    into v_stamp_filled, v_stamp_cycle
    from app.stamp_progress_v323(v_context.business_id, v_context.client_id) sp;$needle$),

      (11, 'public.customer_get_reward_catalog(text)',
       $needle$             when rv.usage_limit is not null and coalesce(usage.used_count, 0) >= rv.usage_limit then 'limit_reached'
             when v_balance < rv.cost_points then 'insufficient_balance'$needle$,
       $needle$             when rv.usage_limit is not null and coalesce(usage.used_count, 0) >= rv.usage_limit then 'limit_reached'
             when v_stamps_programme is not null and rv.programme_id = v_stamps_programme
              and exists (select 1 from public.stamp_milestone_claims claim
                           where claim.business_id = v_context.business_id
                             and claim.client_id = v_context.client_id
                             and claim.programme_id = v_stamps_programme
                             and claim.cycle_index = coalesce(v_stamp_cycle, 0)
                             and claim.reward_id = rv.reward_id) then 'limit_reached'
             when (case when v_stamps_programme is not null and rv.programme_id = v_stamps_programme
                        then coalesce(v_stamp_filled, 0) else v_balance end) < rv.cost_points then 'insufficient_balance'$needle$),

      -- ========== 9. public.customer_get_business_actions_v89 ==========
      -- This is the list the wallet actually renders and the one that decides
      -- whether a Claim affordance is drawn (app/app.js merges it OVER the
      -- catalog), so leaving it points-only would show a Claim button on a
      -- milestone the intent minter then refuses. Named residual, unchanged and
      -- not this migration's: its v_batch_balance is not programme-filtered at
      -- all, so the POINTS path over-reports at a firm holding two pots. R2
      -- makes that shape unreachable, and the fix belongs to the points area.

      (12, 'public.customer_get_business_actions_v89(uuid)',
       $needle$  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;$needle$,
       $needle$  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;
  v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;$needle$),

      (13, 'public.customer_get_business_actions_v89(uuid)',
       $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;$needle$,
       $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps';
  select coalesce(sp.filled,0),coalesce(sp.cycle_index,0)
    into v_stamp_filled,v_stamp_cycle
    from app.stamp_progress_v323(p_business,v_client) sp;$needle$),

      (14, 'public.customer_get_business_actions_v89(uuid)',
       $needle$          when least(v_balance,v_batch_balance)<reward_version.cost_points
            then 'insufficient_balance'$needle$,
       $needle$          when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
            and exists(select 1 from public.stamp_milestone_claims claim
                        where claim.business_id=p_business and claim.client_id=v_client
                          and claim.programme_id=v_stamps_programme
                          and claim.cycle_index=coalesce(v_stamp_cycle,0)
                          and claim.reward_id=reward.id)
            then 'limit_reached'
          when (case when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
                     then coalesce(v_stamp_filled,0)
                     else least(v_balance,v_batch_balance) end)<reward_version.cost_points
            then 'insufficient_balance'$needle$),

      -- ============== 10. public.publish_loyalty_config ==============

      (15, 'public.publish_loyalty_config(uuid)',
       $needle$  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;$needle$,
       $needle$  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) then
    if coalesce(v_typed.stamp_target,0)<=0 then
      raise exception 'a live stamp card needs a number of stamps' using errcode='23514';
    end if;
    if exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
               where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points>v_typed.stamp_target) then
      raise exception 'a stamp gift sits past the last stamp on the card' using errcode='23514';
    end if;
    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points=v_typed.stamp_target) then
      raise exception 'a live stamp card needs a gift at the last stamp' using errcode='23514';
    end if;
  end if;$needle$)

    ) targets(ord, signature, old_text, new_text)
    order by ord
  loop
    if to_regprocedure(v_target.signature) is null then
      raise exception 'v323: needle target is missing: %', v_target.signature
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
      raise exception 'v323: needle % in % matched old=% (expected exactly 1)',
        v_target.ord, v_target.signature, v_o using errcode = '23514';
    end if;
    execute replace(v_def, v_target.old_text, v_target.new_text);
  end loop;
end
$v323_needles$;

-- CREATE OR REPLACE through pg_get_functiondef preserves the existing ACL, so
-- these are re-assertions rather than changes: the reachable roles of every
-- spliced browser-facing body are restated in the file that last touched them.
revoke all privileges on function public.customer_get_reward_catalog(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_reward_catalog(text) to authenticated;
revoke all privileges on function public.customer_get_business_actions_v89(uuid)
  from public, anon, authenticated;
grant execute on function public.customer_get_business_actions_v89(uuid) to authenticated;
revoke all privileges on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11a. public.customer_get_stamp_card_v323 — the customer's read.
--
-- A SEPARATE reader rather than a key on public.customer_get_reward_catalog,
-- and the decisive argument is a live tenant shape: the catalog hard-gates on
-- `exists(loyalty_programs lp where lp.business_id = … and lp.active)` and
-- raises 42501 otherwise. A firm whose spine says stamps-on but whose published
-- programme row is paused would get 42501 on the catalog and see NO CARD AT
-- ALL. Production holds exactly that shape today (Hougang ABC:
-- loyalty_programs.active = false with a real stamps pot). Only a separate
-- reader can serve it.
--
-- IT SPEAKS ONLY IN STAMPS. There is no points figure anywhere in this payload
-- and there must never be one — a v322-era defect was a stamp card printing
-- "points", and the value it printed came from app.c45_base_actionable_wallet_-
-- card, whose balance CTEs carry no programme filter at all.
-- ---------------------------------------------------------------------------

create or replace function public.customer_get_stamp_card_v323(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_context record;
  v_progress record;
  v_milestones jsonb;
  v_metric numeric;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  -- The v300 rule: one key and nothing else, so the client REMOVES the slot
  -- rather than rendering an empty card or a retry affordance.
  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('enabled', false);
  end if;
  select * into v_progress
    from app.stamp_progress_v323(v_context.business_id, v_context.client_id) limit 1;
  if not found then
    return jsonb_build_object('enabled', false);
  end if;

  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'reward_id', rung.reward_id,
    'name', rung.customer_name,
    'slot', rung.cost_points,
    'is_final', rung.cost_points >= coalesce(v_progress.slots, 0)
                and coalesce(v_progress.slots, 0) > 0,
    'claimed_this_cycle', rung.claimed,
    'description', rung.description,
    'image_ref', rung.image_ref,
    'terms', rung.terms,
    'instructions', rung.instructions,
    -- 'claimed_this_cycle' and 'insufficient_stamps' are NEW and confined to this
    -- reader. The shared catalogue vocabulary is deliberately not extended, so
    -- the client's existing availability map cannot meet a word it has no
    -- sentence for during the CDN window.
    'availability', case
      when not v_progress.programme_active then 'paused'
      when rung.claim_available_from is not null and now() < rung.claim_available_from
        then 'not_started'
      when rung.claim_available_until is not null and now() >= rung.claim_available_until
        then 'ended'
      when rung.gate_threshold is not null and v_metric < rung.gate_threshold then 'tier_locked'
      when rung.claimed then 'claimed_this_cycle'
      when rung.usage_limit is not null and rung.used_count >= rung.usage_limit
        then 'limit_reached'
      when v_progress.filled < rung.cost_points then 'insufficient_stamps'
      else 'available_at_counter'
    end,
    'stamps_to_go', greatest(rung.cost_points - v_progress.filled, 0)
  ) order by rung.cost_points, rung.customer_name), '[]'::jsonb)
  into v_milestones
  from (
    select rv.reward_id, rv.customer_name, rv.cost_points, rv.description, rv.image_ref,
           rv.terms, rv.instructions, rv.claim_available_from, rv.claim_available_until,
           rv.usage_limit,
           app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id,
             rv.min_tier_threshold) as gate_threshold,
           (select count(*)::integer from public.loyalty_redemptions lr
             where lr.business_id = v_context.business_id
               and lr.client_id = v_context.client_id
               and lr.reward_id = rv.reward_id) as used_count,
           exists (select 1 from public.stamp_milestone_claims claim
                    where claim.business_id = v_context.business_id
                      and claim.client_id = v_context.client_id
                      and claim.programme_id = v_progress.programme_id
                      and claim.cycle_index = v_progress.cycle_index
                      and claim.reward_id = rv.reward_id) as claimed
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id and rv.config_version_id = b.active_config_version_id and rv.active
     where b.id = v_context.business_id
       and rv.programme_id = v_progress.programme_id
  ) rung;

  return jsonb_build_object(
    'enabled', true,
    'contract', 'v323',
    'unit', 'stamps',
    'running', v_progress.programme_active,
    'running_since', v_progress.running_since,
    'paused_since', v_progress.paused_since,
    'slots', v_progress.slots,
    'filled', v_progress.filled,
    'shown_filled', case when coalesce(v_progress.slots, 0) > 0
                         then least(v_progress.filled, v_progress.slots)
                         else v_progress.filled end,
    'carried', case when coalesce(v_progress.slots, 0) > 0
                    then greatest(v_progress.filled - v_progress.slots, 0) else 0 end,
    'cycle_index', v_progress.cycle_index,
    'lifetime', v_progress.net_stamps,
    'ready', v_progress.ready,
    'pot_migrated', v_progress.pot_migrated,
    'milestones', v_milestones,
    'next_milestone', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> 'claimed_this_cycle')::boolean is not true
       order by (rung.value ->> 'slot')::integer
       limit 1)
  );
end
$$;

revoke all privileges on function public.customer_get_stamp_card_v323(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated;

comment on function public.customer_get_stamp_card_v323(text) is
  'v323 (R5): the customer''s stamp quest — filled/total against the CURRENT cycle, which '
  'milestones are claimed on this card, which is next and how far. Stamps only: this payload '
  'carries no points figure by construction. Returns exactly {"enabled": false} when the firm runs '
  'no stamp card, so the client removes the slot rather than rendering an empty one.';

-- ---------------------------------------------------------------------------
-- 11. Post-assertions. Every claim this file makes, proved. Fail closed.
-- ---------------------------------------------------------------------------

do $v323_post$
declare
  v_def text;
  v_count bigint;
  v_md5 text;
begin
  -- 11.1 The non-consuming claim landed in its contracted shape.
  select pg_get_functiondef(
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure) into strict v_def;
  if position('if v_consumes then' in v_def) = 0
     or position('stamp_milestone_claims' in v_def) = 0
     or position('public.stamp_cycles' in v_def) = 0
     or position('this stamp gift has already been claimed on this card' in v_def) = 0
     or position('app.stamp_progress_v323' in v_def) = 0 then
    raise exception 'v323: the non-consuming claim branch did not land' using errcode = '23514';
  end if;
  -- Exactly one of each: one FEFO loop, one redeem ledger insert, one claim
  -- insert, one cycle insert, one consumption branch. A second copy of any of
  -- them would mean a needle replaced more than it was counted for.
  if (length(v_def) - length(replace(v_def, 'for v_batch in select id,remaining', ''))) /
       length('for v_batch in select id,remaining') <> 1
     or (length(v_def) - length(replace(v_def, 'insert into public.stamp_milestone_claims', ''))) /
       length('insert into public.stamp_milestone_claims') <> 1
     or (length(v_def) - length(replace(v_def, 'insert into public.stamp_cycles', ''))) /
       length('insert into public.stamp_cycles') <> 1
     or (length(v_def) - length(replace(v_def, 'if v_consumes then', ''))) /
       length('if v_consumes then') <> 1
     or (length(v_def) - length(replace(v_def, 'insufficient proven points', ''))) /
       length('insufficient proven points') <> 1 then
    raise exception 'v323: app.redeem_reward_core does not hold exactly one of each spliced form'
      using errcode = '23514';
  end if;
  -- The POINTS path is byte-identical: its affordability pair, its FEFO order,
  -- its ledger row and its scope tokens all still read exactly as before.
  if position($$if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;$$ in v_def) = 0
     or position('order by expires_at nulls last,earned_at,id for update loop' in v_def) = 0
     or position($$'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme$$ in v_def) = 0
     or position($$set_config('app.points_ledger_write_scope','redeem_points',true)$$ in v_def) = 0 then
    raise exception 'v323: the POINTS claim path was disturbed; it must be byte-identical'
      using errcode = '23514';
  end if;

  -- 11.2 The QR mint refuses what the counter would refuse.
  select pg_get_functiondef(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_intent_programme_kind=''stamps''' in v_def) = 0
     or position('this stamp gift has already been claimed on this card' in v_def) = 0
     or position('not enough stamps yet' in v_def) = 0 then
    raise exception 'v323: the stamps gate did not land at the intent minter' using errcode='23514';
  end if;
  -- quoted_points_spent is untouched, so customer_redemption_intents_v89 keeps
  -- its own CHECK (quoted_points_spent > 0) and needs no schema change: the
  -- quote is the milestone's POSITION, which is >= 1 by the reward CHECK.
  if position('v_cost_points,' in v_def) = 0 then
    raise exception 'v323: the intent quote shape changed' using errcode = '23514';
  end if;

  -- 11.3 The money-kernel change, and the proof it rewrote nothing.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.loyalty_redemptions'::regclass
                    and conname = 'loyalty_redemptions_points_spent_check'
                    and pg_get_constraintdef(oid) = 'CHECK ((points_spent >= 0))')
     or not exists (select 1 from pg_constraint
                     where conrelid = 'public.loyalty_redemptions'::regclass
                       and conname = 'loyalty_redemptions_consumption_shape_check')
     or not exists (select 1 from pg_constraint
                     where conrelid = 'public.loyalty_redemption_provenance'::regclass
                       and conname = 'loyalty_redemption_provenance_consumption_shape_check')
     or exists (select 1 from pg_attribute
                 where attrelid = 'public.loyalty_redemption_provenance'::regclass
                   and attname = 'points_ledger_id' and attnotnull) then
    raise exception 'v323: the money-kernel change did not land in its paired shape'
      using errcode = '23514';
  end if;
  select count(*) into strict v_count
    from public.loyalty_redemptions where consumes_balance is not true;
  if v_count <> 0 then
    raise exception 'v323: % redemption(s) did not take the true default', v_count
      using errcode = '23514';
  end if;
  select count(*) into strict v_count
    from public.loyalty_redemption_provenance where consumes_balance is not true;
  if v_count <> 0 then
    raise exception 'v323: % provenance row(s) did not take the true default', v_count
      using errcode = '23514';
  end if;
  select count(*) into strict v_count
    from public.loyalty_redemption_provenance where points_ledger_id is null;
  if v_count <> 0 then
    raise exception 'v323: % legacy provenance row(s) lost their ledger id', v_count
      using errcode = '23514';
  end if;

  -- 11.4 The two tables, their guards, their RLS and their grant floor.
  if to_regclass('public.stamp_cycles') is null
     or to_regclass('public.stamp_milestone_claims') is null then
    raise exception 'v323: the quest tables are missing' using errcode = '23514';
  end if;
  select count(*) into strict v_count from pg_policies
   where schemaname = 'public' and tablename in ('stamp_cycles','stamp_milestone_claims');
  if v_count <> 4 then
    raise exception 'v323: expected exactly 4 policies across the quest tables, found %', v_count
      using errcode = '23514';
  end if;
  if exists (select 1 from pg_policies
              where schemaname = 'public'
                and tablename in ('stamp_cycles','stamp_milestone_claims')
                and cmd <> 'SELECT') then
    raise exception 'v323: a write policy exists on a quest table; every write must be DEFINER'
      using errcode = '23514';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.stamp_cycles'::regclass)
     or not (select relrowsecurity
               from pg_class where oid = 'public.stamp_milestone_claims'::regclass) then
    raise exception 'v323: RLS is not enabled on a quest table' using errcode = '23514';
  end if;
  if has_table_privilege('anon', 'public.stamp_cycles', 'select')
     or has_table_privilege('anon', 'public.stamp_milestone_claims', 'select')
     or has_table_privilege('authenticated', 'public.stamp_cycles', 'insert')
     or has_table_privilege('authenticated', 'public.stamp_milestone_claims', 'insert')
     or not has_table_privilege('authenticated', 'public.stamp_cycles', 'select') then
    raise exception 'v323: the quest table grant floor is not held' using errcode = '23514';
  end if;
  select count(*) into strict v_count from pg_trigger t
   where t.tgrelid in ('public.stamp_cycles'::regclass,
                       'public.stamp_milestone_claims'::regclass)
     and not t.tgisinternal;
  if v_count <> 2 then
    raise exception 'v323: the append-only guards are not both installed (found %)', v_count
      using errcode = '23514';
  end if;

  -- 11.5 The readers.
  if to_regprocedure('app.stamp_progress_v323(uuid,uuid)') is null
     or to_regprocedure('public.customer_get_stamp_card_v323(text)') is null then
    raise exception 'v323: a reader is missing' using errcode = '23514';
  end if;
  if has_function_privilege('authenticated', 'app.stamp_progress_v323(uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.customer_get_stamp_card_v323(text)', 'execute')
     or not has_function_privilege('authenticated',
          'public.customer_get_stamp_card_v323(text)', 'execute') then
    raise exception 'v323: the reader ACL floor is not held' using errcode = '23514';
  end if;
  -- The customer card never speaks in points. Asserted on the body, because the
  -- defect this replaces was a stamp card printing a points figure.
  select pg_get_functiondef('public.customer_get_stamp_card_v323(text)'::regprocedure)
    into strict v_def;
  if position('points_ledger' in v_def) <> 0
     or position('points_batches' in v_def) <> 0
     or position('c45_base_actionable_wallet_card' in v_def) <> 0 then
    raise exception 'v323: the customer stamp card reads a points source' using errcode = '23514';
  end if;

  -- 11.6 THE HARD CONSTRAINT. The W5 earn loop, its arbiter, the in-trigger
  --      parity assertion, the pot migration and both detectors are untouched.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_md5 <> current_setting('v323.on_sale_recorded_md5', true) then
    raise exception 'v323: app.on_sale_recorded changed; the W5 earn loop must be untouched'
      using errcode = '23514';
  end if;
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position('spine.kind in (''points'',''stamps'')' in v_def) = 0
     or position('on conflict (sale_id,programme_id) where entry_type=''earn''' in v_def) = 0
     or position('earn loop left ledger/batch parity broken for sale' in v_def) = 0 then
    raise exception 'v323: the W5 earn loop is not in its v322 shape' using errcode = '23514';
  end if;
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_programmes_v314';
  if v_md5 <> current_setting('v323.set_programmes_md5', true) then
    raise exception 'v323: public.set_programmes_v314 changed; the pot migration writer and the '
      'R2 exclusivity guard must be untouched' using errcode = '23514';
  end if;
  if to_regprocedure('app.enqueue_programme_pot_migration_v312(uuid,uuid,uuid,integer)') is null then
    raise exception 'v323: the pot migration enqueuer is missing' using errcode = '23514';
  end if;
  select count(*) into strict v_count from app.detect_double_earn_v309();
  if v_count <> 0 then
    raise exception 'v323: app.detect_double_earn_v309 is not empty (% rows)', v_count
      using errcode = '23514';
  end if;
  select count(*) into strict v_count from app.detect_programme_pot_split_v312();
  if v_count <> 0 then
    raise exception 'v323: app.detect_programme_pot_split_v312 is not empty (% rows)', v_count
      using errcode = '23514';
  end if;

  -- 11.7 The QR scanner is deliberately out of this migration's md5 chain.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'merchant_scan_redemption_qr_v117';
  if v_md5 <> current_setting('v323.v117_md5', true) then
    raise exception 'v323: public.merchant_scan_redemption_qr_v117 changed; a stamp claim must '
      'satisfy it as it stands, by still writing its provenance row' using errcode = '23514';
  end if;

  -- 11.8 The publish guard that makes closure reachable.
  select pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure) into strict v_def;
  if position('a live stamp card needs a gift at the last stamp' in v_def) = 0
     or position('a live stamp card needs a number of stamps' in v_def) = 0
     or position('a stamp gift sits past the last stamp on the card' in v_def) = 0
     or position('active stamps configuration requires spend per stamp' in v_def) = 0 then
    raise exception 'v323: the stamp publish guards did not land' using errcode = '23514';
  end if;

  -- 11.9 Nothing was written. This migration mints no quest row for anybody.
  select count(*) into strict v_count from public.stamp_cycles;
  if v_count <> 0 then
    raise exception 'v323: % stamp cycle(s) were written by the migration', v_count
      using errcode = '23514';
  end if;
  select count(*) into strict v_count from public.stamp_milestone_claims;
  if v_count <> 0 then
    raise exception 'v323: % milestone claim(s) were written by the migration', v_count
      using errcode = '23514';
  end if;

  raise notice
    'v323 verified: a milestone claim is non-consuming (no ledger row, no batch drain) and is '
    'recorded once per (client, cycle, milestone); the final claim closes the cycle and the card '
    'restarts from the remainder; points_spent >= 0 and a nullable points_ledger_id are both bound '
    'to consumes_balance, so a points reward still cannot record a free claim; the W5 earn loop, '
    'the (sale, programme) arbiter, the parity assertion, the pot migration and both detectors are '
    'untouched; merchant_scan_redemption_qr_v117 is byte-identical and still finds its provenance '
    'row.';
end
$v323_post$;

commit;
