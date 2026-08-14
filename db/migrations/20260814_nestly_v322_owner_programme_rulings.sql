-- nestly_v322_owner_programme_rulings
--
-- OWNER RULINGS 2026-08-14 (evening), the SERVER half. R1, R2, R3 and R4 of
-- docs/qa/evidence/V322-OWNER-PROGRAMME-RULINGS-ACCEPTANCE.md. R5 and R6 are client-only and
-- ship in app/app.js in the same change; nothing in this file touches them.
--
-- WHAT THIS IS. Two owner corrections that both land on money paths, plus the guard that makes
-- one of them enforceable:
--
--   R1/R4 — REFERRAL STOPS PAYING STORE CREDIT AND PAYS POINTS.
--     "why referral is a stored credits? please remove it as i already said no more store credits"
--     "referral is universal - and supposed to be free item (customer receive voucher and come to
--      store to claim it or maybe give points)"
--     Spendable credit left the product at v320 (8d44f46) and the referral payout did not go with
--     it: app.on_sale_recorded still minted public.credit_ledger entry_type='referral_reward'.
--     After this migration the referral block writes ONE points_ledger 'earn' row and its matching
--     points_batches row, tagged with the referrer's own firm's accruing programme, and writes NO
--     credit at all. THE VOUCHER HALF OF R4 IS DELIBERATELY NOT BUILT — see "WHAT IS DEFERRED".
--
--   R2/R3 — STAMPS IS EXCLUSIVE.
--     "stamps is not supposed to be able to be live with points and tier. - it is seperate rewards
--      by itself." / "points / tier / points & tier"
--     The legal accrual shapes are points | tier | points+tier | stamps. Referral is orthogonal and
--     is NEVER part of the exclusivity. W5 (v311/v312) deliberately removed the v308 tripwire so
--     one sale could earn points AND a stamp; that capability is now unwanted. The guard comes back
--     at public.set_programmes_v314 — the ONE writer of the spine (V314 standing invariant) — as a
--     refusal with a sentence an owner can act on, not a raw constraint violation.
--
-- WHAT THIS IS NOT. The W5 money kernel is KEPT EXACTLY AS IT IS. Per-programme ledger tagging,
-- the (sale, programme) earn arbiter (points_earn_once_per_sale_per_programme), the pot migration
-- (app.enqueue_programme_pot_migration_v312) and both detectors are all still correct and still
-- needed — stamps still earns into its own programme pot. THIS IS NOT A REVERT OF v311/v312. The
-- earn loop simply will never again see two accruing programmes at once, because the switch RPC
-- refuses to create that state. Not one line of app.on_sale_recorded's EARN LOOP is touched; the
-- only needle into that function is the referral block at its tail.
--
-- WHY THE REFERRAL EARN ROW CARRIES sale_id = NULL, stated because it looks like a mistake.
-- points_earn_once_per_sale_per_programme is UNIQUE (sale_id, programme_id) WHERE entry_type='earn'
-- AND sale_id IS NOT NULL. The referral payout goes to the REFERRER, who is not the sale's client,
-- but it is triggered by the referred friend's sale — so tagging it with that sale_id would collide
-- with the friend's own earn row in the same programme and abort the whole sale trigger with 23505
-- the first time a referred friend's qualifying visit also earned points. That is every firm that
-- runs points and referral together, which is the common case. sale_id stays NULL; the sale is
-- recorded where it belongs, on public.referrals.qualified_sale_id, which this block already sets.
-- Three consequences, all intended: the arbiter cannot see the row (correct — it is not that sale's
-- earn), app.detect_double_earn_v309 cannot see it (correct, same reason), and on_sale_recorded's
-- own ledger/batch parity check (which counts rows WHERE sale_id = new.id) is unaffected, because
-- neither the ledger row nor the batch row carries the sale.
--
-- WHICH POT A REFERRAL PAYS INTO. app.referral_payout_programme_v322 answers, and it answers
-- "the firm's one active accruing programme" rather than "points". Referral is UNIVERSAL (R4): it
-- runs alongside any shape including stamps, and paying points into a switched-off points row at a
-- stamps firm would mint a balance app.redeem_reward_core refuses to spend ("catalog redemption is
-- inactive"). Under R2 there is never more than one accruing programme, so the answer is unique.
-- When there is NO active accruing programme the referral is LEFT PENDING and nothing is written:
-- it will pay on the next qualifying visit after the owner switches a programme on. Fail closed,
-- never a silent unspendable balance. Two live firms are in exactly that state today — see the
-- acceptance document's "what the three live rows now pay".
--
-- WHAT IS DEFERRED, NAMED RATHER THAN IMPLIED.
--   · The VOUCHER payout of R4 ("customer receive voucher and come to store to claim it"). Only the
--     POINTS payout is built, because it reuses the points ledger and needs no new machinery. The
--     data shape carries the deferral explicitly: referral_programs.reward_kind is CHECKed against
--     ('points','voucher') and defaults to 'points'; nothing writes 'voucher' and the engine pays
--     only 'points', so a voucher row cannot exist and cannot be paid by accident.
--   · referral_programs.reward_cents is NOT dropped and NOT redefined. It stays exactly as it is,
--     as the historical record of what each firm used to pay in money, and NOTHING READS IT ANY
--     MORE on the payout path. Renaming its meaning in place was considered and rejected: a column
--     whose unit silently changed is how two readers end up disagreeing by a factor of a hundred.
--     public.save_referral_program (the four-argument, pre-v322 signature) is likewise left
--     installed and granted, so the CDN-cached bundle keeps writing that column harmlessly for its
--     four-hour window instead of failing in front of an owner. The new door is
--     public.save_referral_program_v322.
--
-- ROLLBACK, SAID OUT LOUD. Every change here is additive or a needle, and each reverses on its own:
-- re-splice app.on_sale_recorded's referral block back to the credit_ledger insert (the pre-image is
-- in this file, verbatim, as the needle's old_text), re-splice app.loyalty_ledger_write_guard to
-- drop the 'referral_reward_points' scope, re-splice public.set_programmes_v314 to drop the
-- exclusivity block, and drop the two new columns and the three new functions. Reverting the
-- referral needle does NOT convert points already paid back into credit — those points_ledger rows
-- are append-only and stay. That is the rollback; it belongs here, not in an incident.
--
-- MONEY SCOPE. This migration writes no credit_ledger row, no points_ledger row, no points_batches
-- row and no sale. It adds two nullable-by-default columns with a backfill computed from each
-- firm's own published points price, three functions, and three counted needles.

begin;

-- ---------------------------------------------------------------------------
-- -1. Deterministic lock acquisition. Same prelude, same reason, as v313/v314:
-- the 2026-08-14 production incident (three identical 40P01s) is cured
-- structurally by taking everything contested up front in one ordered
-- acquisition, so no cycle can form. storage.objects is conditional because
-- rigs replay app/public only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '25s';

do $v322_prelock$
begin
  if to_regclass('storage.objects') is not null then
    execute 'lock table storage.objects in access exclusive mode';
  end if;
end
$v322_prelock$;

lock table public.businesses, public.referral_programs, public.referrals,
           public.business_programmes
  in access exclusive mode;

-- ---------------------------------------------------------------------------
-- 0. Predecessor pins and preconditions. Fail closed.
--
-- (a) The already-applied guard, so a re-run is a refusal and never a partial
--     second pass.
-- (b) The md5 pin table. Every hash below was READ LIVE from
--     gadpooereceldfpfxsod on 2026-08-14, after v313 + v314. They are RAW
--     md5(prosrc) because none of these four bodies carries a full-line
--     comment in production (a production apply_migration strips them), so the
--     raw and comment-normalised forms are identical for all four.
-- (c) THE R2 PRECONDITIONS. The owner rulings document states, and this
--     migration REQUIRES, that no live firm is currently in the state the new
--     guard forbids. If that has stopped being true between the ruling and the
--     apply, the guard would strand a firm whose stamps programme this
--     migration cannot honestly turn off on their behalf — so the migration
--     refuses instead of guessing.
-- ---------------------------------------------------------------------------

do $v322_pins$
declare
  v_md5 text;
  v_count bigint;
begin
  if to_regprocedure('app.referral_payout_programme_v322(uuid)') is not null then
    raise exception 'v322 is already applied (app.referral_payout_programme_v322 exists)'
      using errcode = '23514';
  end if;

  -- (b) THE PIN TABLE.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_md5 <> '094f7f8e2be24cea0a8d9d3e8fbacfdc' then
    raise exception 'v322: app.on_sale_recorded is not the v314 post-state body (md5=%)', v_md5
      using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'loyalty_ledger_write_guard';
  if v_md5 <> '7f5590449570d76051feed93d182487f' then
    raise exception 'v322: app.loyalty_ledger_write_guard is not the v312 post-state body (md5=%)',
      v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_programmes_v314';
  if v_md5 <> 'fe0d353ec384d84540fa5717fadec307' then
    raise exception 'v322: public.set_programmes_v314 is not the v314 post-state body (md5=%)',
      v_md5 using errcode = '23514';
  end if;

  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_referral_card_v300';
  if v_md5 <> 'a182dbd597c930a771df25a200464477' then
    raise exception 'v322: public.customer_get_referral_card_v300 is not the v300 body (md5=%)',
      v_md5 using errcode = '23514';
  end if;

  -- Notice-only: this body is not edited, but the new writer must agree with it.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_referral_program';
  raise notice 'v322: public.save_referral_program(uuid,boolean,integer,integer) left installed at md5=%',
    v_md5;

  -- (c) THE R2 PRECONDITIONS.
  select count(*) into strict v_count
    from public.business_programmes spine
   where spine.kind = 'stamps' and spine.active;
  if v_count <> 0 then
    raise exception 'v322: % business(es) already run the stamps programme; the R2 exclusivity '
      'guard would be applied over a live state it cannot resolve. Switch them by hand first.',
      v_count using errcode = '23514';
  end if;

  select count(*) into strict v_count
    from (select spine.business_id
            from public.business_programmes spine
           where spine.active and spine.kind in ('points','tiers','stamps')
           group by spine.business_id
          having bool_or(spine.kind = 'stamps')
             and bool_or(spine.kind in ('points','tiers'))) forbidden;
  if v_count <> 0 then
    raise exception 'v322: % business(es) run stamps alongside points or tiers, which R2 forbids; '
      'the guard cannot be added over them', v_count using errcode = '23514';
  end if;

  raise notice 'v322: pins met; zero firms run stamps, zero firms are in the forbidden shape.';
end
$v322_pins$;

-- ---------------------------------------------------------------------------
-- 1. The referral payout's own columns (R1/R4).
--
-- reward_points is the amount, and it is a NEW column rather than a re-read of
-- reward_cents, because a column whose unit changes underneath its readers is
-- the defect this ruling exists to fix, not a shortcut through it.
--
-- reward_kind is the DEFERRAL, made explicit. R4 names two payouts — a voucher
-- for a free item, or points — and only points is built. A row can only say
-- 'points' today (nothing writes 'voucher') and the engine pays only 'points',
-- so the unbuilt half cannot be reached by accident, and building it later is
-- an UPDATE and a branch rather than a migration of live rows.
-- ---------------------------------------------------------------------------

alter table public.referral_programs
  add column reward_points integer not null default 0,
  add column reward_kind text not null default 'points';

alter table public.referral_programs
  add constraint referral_programs_reward_points_check check (reward_points >= 0),
  add constraint referral_programs_reward_kind_check check (reward_kind in ('points','voucher'));

comment on column public.referral_programs.reward_points is
  'v322 (owner ruling R1/R4): what a qualifying referral pays the referrer, in POINTS, into the '
  'firm''s one active accruing programme. Referral no longer pays store credit. reward_cents is '
  'the frozen historical money amount and is read by nothing on the payout path.';
comment on column public.referral_programs.reward_kind is
  'v322 (owner ruling R4): ''points'' is the only payout built. ''voucher'' (a free item the '
  'customer claims at the counter) is DEFERRED; nothing writes it and app.on_sale_recorded pays '
  'only ''points'', so a voucher row cannot be paid by accident.';
comment on column public.referral_programs.reward_cents is
  'FROZEN at v322. The historical money amount this firm used to pay a referrer in store credit. '
  'Store credit left the product at v320 and the referral payout followed at v322; nothing on the '
  'payout path reads this column any more. Kept, not dropped, so the old value is recoverable and '
  'so the pre-v322 save_referral_program signature keeps working through its CDN window.';

-- public.referrals carries the amount that was actually paid, for the activity
-- table and for any later reversal. It gains the points column for the same
-- reason the programme did; reward_cents on this table is frozen identically.
alter table public.referrals
  add column reward_points integer not null default 0;

alter table public.referrals
  add constraint referrals_reward_points_check check (reward_points >= 0);

comment on column public.referrals.reward_points is
  'v322: the POINTS actually paid to the referrer when this referral qualified. reward_cents is '
  'the frozen pre-v322 money amount.';

-- ---------------------------------------------------------------------------
-- 2. The backfill, and the one judgement call in this file.
--
-- Three live rows carry a money amount (1000 / 300 / 1000 cents). They have to
-- become a points amount, and blanking them would silently stop three firms
-- paying a referral reward they believe they are paying.
--
-- The conversion is each firm's OWN published points price: reward_credit_cents
-- points-per-cent, i.e. points = cents * redeem_points / reward_credit_cents.
-- That is the number of points which buys exactly the same value of gifts at
-- that firm's own rate, so the owner's intended generosity is preserved rather
-- than reinterpreted. A firm with no usable ratio (either column zero, null or
-- absent) gets 0 and is NAMED in the notice — a zero payout is visible and
-- fixable in one screen, an invented one is not.
--
-- The exact result is reported as a NOTICE and recorded in the acceptance
-- document, business by business, because three real owners are about to pay a
-- different-looking number.
-- ---------------------------------------------------------------------------

do $v322_backfill$
declare
  v_row record;
  v_total integer := 0;
  v_zero integer := 0;
begin
  for v_row in
    select rp.business_id,
           rp.reward_cents,
           case when coalesce(lp.reward_credit_cents,0) > 0 and coalesce(lp.redeem_points,0) > 0
                then round(rp.reward_cents::numeric * lp.redeem_points / lp.reward_credit_cents)::integer
                else 0 end as points
      from public.referral_programs rp
      left join public.loyalty_programs lp on lp.business_id = rp.business_id
     where rp.reward_points = 0
  loop
    update public.referral_programs
       set reward_points = v_row.points
     where business_id = v_row.business_id;
    v_total := v_total + 1;
    if v_row.points = 0 then
      v_zero := v_zero + 1;
      raise notice 'v322 backfill: business % had % cents and NO usable points price; '
        'its referral now pays 0 points until the owner sets one',
        v_row.business_id, v_row.reward_cents;
    else
      raise notice 'v322 backfill: business % — % cents -> % points',
        v_row.business_id, v_row.reward_cents, v_row.points;
    end if;
  end loop;
  raise notice 'v322 backfill: % referral programme(s) converted, % of them to zero',
    v_total, v_zero;
end
$v322_backfill$;

-- ---------------------------------------------------------------------------
-- 3. app.referral_payout_programme_v322 — WHICH POT A REFERRAL PAYS INTO.
--
-- The firm's one ACTIVE accruing programme, or null. Under R2 there is never
-- more than one, so "the one" is well defined; the count(*) over () guard is
-- kept anyway so that a firm which somehow holds two accruing rows gets a null
-- (and therefore no payout) instead of an arbitrary pick. Points is preferred
-- over stamps only as a tie-break that R2 makes unreachable.
--
-- It is deliberately NOT app.reward_default_programme_v313: that function falls
-- back to the points row when nothing is running, which is the right answer for
-- AUTHORING a reward (a gift priced in a paused programme is fine, it starts
-- working when the programme does) and the wrong one for PAYING (a balance in a
-- paused programme cannot be spent and the customer was told they had it).
-- ---------------------------------------------------------------------------

create or replace function app.referral_payout_programme_v322(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select accruing.id
    from (select spine.id, spine.kind, count(*) over () as active_accruing
            from public.business_programmes spine
           where spine.business_id = p_business
             and spine.active
             and spine.kind in ('points','stamps')) accruing
   where accruing.active_accruing = 1
$$;

revoke all privileges on function app.referral_payout_programme_v322(uuid)
  from public, anon, authenticated;

comment on function app.referral_payout_programme_v322(uuid) is
  'v322 (R1/R4): the business''s ONE active accruing programme, or null. The pot a qualifying '
  'referral pays its points into. Null means the referral is left pending and nothing is written.';

-- ---------------------------------------------------------------------------
-- 4. app.emit_referral_qualified_v322 — the fulfilment trail, preserved.
--
-- app.trg_emit_referral_qualified (v56:555) fires AFTER INSERT ON credit_ledger
-- WHEN entry_type='referral_reward'. Once the payout stops writing credit that
-- trigger stops firing, and it is NOT dead code: production holds 11 referral
-- rows in public.benefit_registry with cutover_status='shadow', one
-- benefit_fulfilments row and one referral.qualified domain event. Dropping a
-- caller's only entry point silently is the failure mode this repo has already
-- paid for, so the same two writes are re-expressed here and called directly
-- from the referral block. The trigger and its function are LEFT INSTALLED and
-- untouched, so a pre-v322 credit row (a rollback, a replay) still emits.
--
-- The one honest change is the costing. face_value_cents was the credit's own
-- amount under cost_basis='credit_face'; points have no face value until they
-- are priced, so the value is computed from the firm's own published points
-- price (the same ratio the backfill used) under cost_basis='bonus_face', which
-- is the allowed basis that actually describes a points bonus. A firm with no
-- usable ratio records 0 with cost_confidence='low' rather than a guess.
-- ---------------------------------------------------------------------------

create or replace function app.emit_referral_qualified_v322(
  p_business uuid,
  p_referral uuid,
  p_referrer uuid,
  p_referred uuid,
  p_points integer,
  p_ledger uuid,
  p_occurred_at timestamptz,
  p_config_version uuid
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_cut text;
  v_value integer := 0;
  v_confidence text := 'low';
  v_config uuid;
begin
  -- public.sales.config_version_id is NULLABLE while benefit_fulfilments.config_version_id is NOT
  -- NULL, so the fulfilment row needs a version and the sale may not carry one. The old credit-side
  -- trigger never met this: app.stamp_config_version fills the column on every credit_ledger row
  -- before the emitter reads it. Fall back to the business's active version, and when there is not
  -- one, record NO fulfilment rather than abort a customer's sale over an accounting row. The
  -- domain event has a nullable version and is emitted either way.
  select coalesce(p_config_version, b.active_config_version_id) into v_config
    from public.businesses b where b.id = p_business;

  select case when coalesce(lp.reward_credit_cents,0) > 0 and coalesce(lp.redeem_points,0) > 0
              then round(p_points::numeric * lp.reward_credit_cents / lp.redeem_points)::integer
              else 0 end
    into v_value
    from public.loyalty_programs lp
   where lp.business_id = p_business
   limit 1;
  v_value := coalesce(v_value, 0);
  if v_value > 0 then v_confidence := 'high'; end if;

  perform app.emit_domain_event(p_business, 'referral.qualified',
    'referral_qualify:' || p_referral::text,
    p_referred, null, p_occurred_at, p_config_version,
    jsonb_build_object('referral_id', p_referral, 'referrer_client_id', p_referrer,
      'referred_client_id', p_referred, 'reward_points', p_points,
      'points_ledger_id', p_ledger));

  select cutover_status into v_cut from public.benefit_registry
   where business_id = p_business and source_engine = 'referral';
  if v_cut in ('shadow','studio') and v_config is not null then
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id,
      occurred_at)
    values(p_business, 'referral:' || p_referral::text, 'referral', 'referral_reward',
      p_referrer, p_ledger, v_value, v_value, 'bonus_face', v_confidence, v_config,
      p_occurred_at)
    on conflict (business_id, canonical_benefit_key) do nothing;
  end if;
end
$$;

revoke all privileges on function app.emit_referral_qualified_v322(uuid,uuid,uuid,uuid,integer,uuid,timestamptz,uuid)
  from public, anon, authenticated;

comment on function app.emit_referral_qualified_v322(uuid,uuid,uuid,uuid,integer,uuid,timestamptz,uuid) is
  'v322: the referral.qualified domain event and the shadow benefit_fulfilments row that '
  'app.trg_emit_referral_qualified used to write off a credit_ledger insert. The payout is points '
  'now, so the trigger no longer fires and the referral block calls this instead.';

-- ---------------------------------------------------------------------------
-- 5. NEEDLE 1 — app.loyalty_ledger_write_guard learns the referral scope.
--
-- Every points_ledger insert must name an approved internal route and match
-- that route's shape. The referral payout is a NEW route and it deliberately
-- does not fit any existing one: 'sale_trigger' requires sale_id IS NOT NULL,
-- which is precisely what the referral row must not carry (see the header).
-- So it gets its own scope and its own shape rule, and the shape rule is what
-- stops that scope from becoming a general-purpose hole: earn, positive, no
-- sale, and a programme.
--
-- Both needles anchor on comment-free code (GUARD 3): this body carries no
-- full-line comments in production, and neither needle spans one anyway.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 6. NEEDLE 2 — app.on_sale_recorded's referral block pays points.
--
-- The needle is the whole block, so the pre-image is preserved verbatim in this
-- file as the rollback. Note what does NOT change: the qualification test
-- (a pending referral for this client, the programme enabled, the sale at or
-- above min_spend_cents), the once-only UPDATE ... WHERE status='pending', and
-- the fact that the whole thing sits inside `if new.counts_as_visit`.
--
-- What changes: the payout. Resolve the pot; resolve the amount; if either is
-- missing, LEAVE THE REFERRAL PENDING and write nothing at all, so it pays on
-- the next qualifying visit once the owner has switched a programme on. The
-- expiry the batch carries is the firm's own published expiry, re-resolved
-- here rather than borrowed from the earn loop's `lp`, which is only populated
-- when the sale earned points — a referral can qualify on a visit that earned
-- nothing.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 7. NEEDLE 3 — public.set_programmes_v314 enforces R2/R3.
--
-- The guard is computed on the RESULT of the call, not on its arguments: the
-- switch payload is legitimately PARTIAL after R6 (the wizard now sends only
-- the programmes the owner is actually setting up), so "does this leave stamps
-- next to points?" can only be answered by merging the payload over the spine
-- as it stands. It is placed after the self-heal insert (so every kind has a
-- row to read) and before the flip loop (so nothing is written when the answer
-- is no).
--
-- The message is the owner's, not the database's: it names the shape and the
-- one action that resolves it. Errcode 22023 matches every other argument
-- refusal this function raises, so the client's existing error rendering
-- already carries it to the screen.
-- ---------------------------------------------------------------------------

do $v322_needles$
declare
  v_def text;
  v_o integer;
  v_n integer;
  v_target record;
begin
  for v_target in
    select * from (values

      -- ---- NEEDLE 1a. app.loyalty_ledger_write_guard, the scope allowlist. ----
      (1, 'app.loyalty_ledger_write_guard()',
       $needle$       ('sale_trigger','redeem_points','adjust_points','points_expiry',
        'redemption_reversal','sale_amount_correction_v84','programme_pot_transfer') then$needle$,
       $needle$       ('sale_trigger','redeem_points','adjust_points','points_expiry',
        'redemption_reversal','sale_amount_correction_v84','programme_pot_transfer',
        'referral_reward_points') then$needle$),

      -- ---- NEEDLE 1b. app.loyalty_ledger_write_guard, the shape rule. --------
      -- Appended to the tail of the same `if` chain, anchored on the last arm.
      (2, 'app.loyalty_ledger_write_guard()',
       $needle$       or (v_scope='programme_pot_transfer'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is not null or new.programme_id is null)) then$needle$,
       $needle$       or (v_scope='programme_pot_transfer'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is not null or new.programme_id is null))
       or (v_scope='referral_reward_points'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is not null
               or new.programme_id is null)) then$needle$),

      -- ---- NEEDLE 2a. app.on_sale_recorded, the declarations. ----------------
      (3, 'app.on_sale_recorded()',
       $needle$declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;$needle$,
       $needle$declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_refcfg record; v_ref_prog uuid; v_ref_points integer;$needle$),

      -- ---- NEEDLE 2b. app.on_sale_recorded, the referral payout. -------------
      (4, 'app.on_sale_recorded()',
       $needle$      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_cents=refprog.reward_cents where id=refrow.id and status='pending';
        if found then
          v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
          insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,refrow.referrer_client_id,'referral_reward',refprog.reward_cents,'referral qualified: first visit completed',new.id,auth.uid());
          perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
        end if;
      end if;$needle$,
       $needle$      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        v_ref_prog:=case when refprog.reward_kind='points' then app.referral_payout_programme_v322(new.business_id) end;
        v_ref_points:=coalesce(refprog.reward_points,0);
        if v_ref_prog is not null and v_ref_points>0 then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_points=v_ref_points where id=refrow.id and status='pending';
          if found then
            v_expires:=null;
            select * into v_refcfg from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
            if found and v_refcfg.expiry_mode='fixed' then v_expires:=now()+make_interval(days=>v_refcfg.expiry_days); end if;
            v_earn_id:=gen_random_uuid();
            perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
            insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
            values(v_earn_id,new.business_id,refrow.referrer_client_id,'earn',v_ref_points,null,'referral qualified: first visit completed',auth.uid(),v_ref_prog);
            perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,refrow.referrer_client_id,v_ref_points,v_ref_points,null,now(),v_expires,v_ref_prog);
            perform app.emit_referral_qualified_v322(new.business_id,refrow.id,refrow.referrer_client_id,new.client_id,v_ref_points,v_earn_id,now(),new.config_version_id);
          end if;
        end if;
      end if;$needle$),

      -- ---- NEEDLE 3a. public.set_programmes_v314, the declarations. ----------
      (5, 'public.set_programmes_v314(uuid,jsonb,uuid)',
       $needle$  v_migration uuid;
begin$needle$,
       $needle$  v_migration uuid;
  v_after_points boolean;
  v_after_tiers boolean;
  v_after_stamps boolean;
begin$needle$),

      -- ---- NEEDLE 3b. public.set_programmes_v314, the R2/R3 exclusivity. -----
      (6, 'public.set_programmes_v314(uuid,jsonb,uuid)',
       $needle$  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry$needle$,
       $needle$  select coalesce((p_switches ->> 'points')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce((p_switches ->> 'tiers')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'tiers'), false),
         coalesce((p_switches ->> 'stamps')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_after_points, v_after_tiers, v_after_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if v_after_stamps and (v_after_points or v_after_tiers) then
    raise exception 'The stamp card runs on its own. Turn Points & gifts and Tier membership off '
      'before turning the stamp card on, or turn the stamp card off to run points and tiers.'
      using errcode = '22023';
  end if;

  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry$needle$)

    ) targets(ord, signature, old_text, new_text)
    order by ord
  loop
    if to_regprocedure(v_target.signature) is null then
      raise exception 'v322: needle target is missing: %', v_target.signature
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
      raise exception 'v322: needle % in % matched old=% (expected exactly 1)',
        v_target.ord, v_target.signature, v_o using errcode = '23514';
    end if;
    execute replace(v_def, v_target.old_text, v_target.new_text);
  end loop;
end
$v322_needles$;

-- ---------------------------------------------------------------------------
-- 8. public.save_referral_program_v322 — the points writer.
--
-- A NEW signature rather than a re-bodied one, for the CDN reason v314 wrote
-- down: /app-*.js is pinned ~4h, so the previous bundle keeps calling the
-- four-argument money signature for that long. Breaking it would surface as a
-- failed save in front of an owner. Both doors write the SAME row; the old one
-- writes the frozen money column the payout no longer reads, the new one writes
-- the points the payout does read. The overlap window is four hours and its
-- worst outcome is a stale money number in a column nothing consults.
--
-- reward_kind is not an argument. Nothing may write 'voucher' until the voucher
-- payout exists, and an argument nobody is allowed to use is how it gets used.
-- ---------------------------------------------------------------------------

create or replace function public.save_referral_program_v322(
  p_business uuid,
  p_enabled boolean,
  p_reward_points integer,
  p_min_spend_cents integer
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_program public.referral_programs%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'referrals') then
    raise exception 'active referrals-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if p_enabled is null or p_reward_points is null or p_reward_points < 0
     or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;
  insert into public.referral_programs (business_id, enabled, reward_points, min_spend_cents)
  values (p_business, p_enabled, p_reward_points, p_min_spend_cents)
  on conflict (business_id) do update set
    enabled = excluded.enabled,
    reward_points = excluded.reward_points,
    min_spend_cents = excluded.min_spend_cents
  returning * into v_program;
  return jsonb_build_object('status','completed','program_id',v_program.id,
    'enabled',v_program.enabled,'reward_points',v_program.reward_points,
    'reward_kind',v_program.reward_kind,
    'min_spend_cents',v_program.min_spend_cents);
end
$$;

-- schema public carries a Supabase DEFAULT ACL that grants EXECUTE to anon and authenticated
-- EXPLICITLY on every new function, so `revoke ... from public` (the pseudo-role) leaves anon's
-- own grant in place. The ACL floor below caught exactly that on the first apply attempt. Name
-- the roles, the way v313/v314 do.
revoke all privileges on function public.save_referral_program_v322(uuid,boolean,integer,integer)
  from public, anon, authenticated;
grant execute on function public.save_referral_program_v322(uuid,boolean,integer,integer)
  to authenticated;

comment on function public.save_referral_program_v322(uuid,boolean,integer,integer) is
  'v322 (R1/R4): the referral programme writer that speaks POINTS. Same authorization and same row '
  'as the pre-v322 four-argument money signature, which stays installed for the CDN window.';

-- ---------------------------------------------------------------------------
-- 9. public.customer_get_referral_card_v300 tells the customer the truth.
--
-- The card said "you get SGD 10 in credit". The engine now pays points, so the
-- reader has to carry them. reward_cents and currency are KEPT in the payload —
-- the cached customer bundle reads them for another four hours and a missing
-- key would blank the card mid-window — and reward_points / reward_kind are
-- added beside them. The new bundle reads points and ignores the money keys.
-- Everything else in this body, including the disabled-programme early return
-- that makes the card vanish rather than tease, is byte-identical.
-- ---------------------------------------------------------------------------

create or replace function public.customer_get_referral_card_v300(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_program record;
  v_code text;
  v_referred integer := 0;
  v_enabled boolean := false;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;
  select identity_id, business_id, client_id, business_currency, enabled_modules
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  select rp.enabled, rp.reward_cents, rp.reward_points, rp.reward_kind, rp.min_spend_cents
    into v_program
    from public.referral_programs rp
   where rp.business_id = v_context.business_id
   limit 1;
  v_enabled := coalesce(v_program.enabled, false)
    and 'referrals' = any(coalesce(v_context.enabled_modules, '{}'::text[]));
  if not v_enabled then
    return jsonb_build_object('enabled', false);
  end if;
  select c.referral_code into v_code
    from public.clients c
   where c.id = v_context.client_id;
  select count(*)::integer into v_referred
    from public.referrals r
   where r.business_id = v_context.business_id
     and r.referrer_client_id = v_context.client_id
     and r.status in ('qualified','rewarded');
  return jsonb_build_object(
    'enabled', true,
    'code', v_code,
    'reward_cents', coalesce(v_program.reward_cents, 0),
    'reward_points', coalesce(v_program.reward_points, 0),
    'reward_kind', coalesce(v_program.reward_kind, 'points'),
    'min_spend_cents', coalesce(v_program.min_spend_cents, 0),
    'currency', coalesce(v_context.business_currency, 'SGD'),
    'referred_count', v_referred
  );
end
$$;

-- CREATE OR REPLACE preserves an existing ACL, so this pair is a re-assertion
-- rather than a change: the v300 grant list is restated verbatim so the
-- customer reader's reachable roles are visible in the file that last touched
-- it, and so the house guard can see them.
revoke all privileges on function public.customer_get_referral_card_v300(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_referral_card_v300(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Post-assertions. Fail closed.
-- ---------------------------------------------------------------------------

do $v322_post$
declare
  v_def text;
  v_count bigint;
begin
  -- 10.1 The referral payout writes points and no credit.
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position('referral_reward_points' in v_def) = 0
     or position('app.referral_payout_programme_v322' in v_def) = 0
     or position('app.emit_referral_qualified_v322' in v_def) = 0
     or position($$'referral_reward'$$ in v_def) <> 0
     or position('refprog.reward_cents' in v_def) <> 0 then
    raise exception 'v322: the referral payout flip did not land in its contracted shape'
      using errcode = '23514';
  end if;

  -- 10.2 The EARN LOOP is untouched. This is the "not a revert of v311/v312"
  --      claim, asserted rather than promised.
  if position('spine.kind in (''points'',''stamps'')' in v_def) = 0
     or position('on conflict (sale_id,programme_id) where entry_type=''earn''' in v_def) = 0
     or position('earn loop left ledger/batch parity broken for sale' in v_def) = 0 then
    raise exception 'v322: the W5 earn loop was disturbed; this migration must not touch it'
      using errcode = '23514';
  end if;

  -- 10.3 The write guard knows the new scope and constrains it.
  select pg_get_functiondef('app.loyalty_ledger_write_guard()'::regprocedure) into strict v_def;
  if position($$'referral_reward_points') then$$ in v_def) = 0
     or position($$v_scope='referral_reward_points'$$ in v_def) = 0
     -- The referral arm is the only one that ends the chain, so this exact tail
     -- appears once and only if the shape rule landed with the scope.
     or position('or new.programme_id is null)) then' in v_def) = 0 then
    raise exception 'v322: the referral ledger scope is missing or unconstrained'
      using errcode = '23514';
  end if;

  -- 10.4 The exclusivity guard is in the ONE writer, and it is computed on the
  --      merged result rather than on the payload.
  select pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)
    into strict v_def;
  if position('The stamp card runs on its own' in v_def) = 0
     or position('v_after_stamps and (v_after_points or v_after_tiers)' in v_def) = 0
     or position($$coalesce((p_switches ->> 'points')::boolean$$ in v_def) = 0 then
    raise exception 'v322: the R2 exclusivity guard did not land at set_programmes_v314'
      using errcode = '23514';
  end if;
  -- Referral is orthogonal (R4) and must never appear in the guard.
  if position('v_after_referral' in v_def) <> 0 then
    raise exception 'v322: referral must not be part of the exclusivity guard'
      using errcode = '23514';
  end if;

  -- 10.5 The columns, their checks and the backfill.
  if to_regprocedure('public.save_referral_program_v322(uuid,boolean,integer,integer)') is null
     or to_regprocedure('public.save_referral_program(uuid,boolean,integer,integer)') is null then
    raise exception 'v322: both referral writers must be installed' using errcode = '23514';
  end if;
  select count(*) into strict v_count from public.referral_programs where reward_kind <> 'points';
  if v_count <> 0 then
    raise exception 'v322: % referral programme(s) claim a payout kind that is not built', v_count
      using errcode = '23514';
  end if;

  -- 10.6 The W5 detectors are still empty. Nothing here writes money, so a
  --      non-empty detector means this migration met a state it did not expect.
  select count(*) into strict v_count from app.detect_double_earn_v309();
  if v_count <> 0 then
    raise exception 'v322: app.detect_double_earn_v309 is not empty (% rows)', v_count
      using errcode = '23514';
  end if;
  select count(*) into strict v_count from app.detect_programme_pot_split_v312();
  if v_count <> 0 then
    raise exception 'v322: app.detect_programme_pot_split_v312 is not empty (% rows)', v_count
      using errcode = '23514';
  end if;

  -- 10.7 ACL floor. The new writer is callable by an authenticated owner and by
  --      nobody else; the two app-schema helpers are internal.
  if not has_function_privilege('authenticated',
       'public.save_referral_program_v322(uuid,boolean,integer,integer)', 'execute')
     or has_function_privilege('anon',
       'public.save_referral_program_v322(uuid,boolean,integer,integer)', 'execute')
     or has_function_privilege('authenticated', 'app.referral_payout_programme_v322(uuid)', 'execute')
     or has_function_privilege('authenticated',
       'app.emit_referral_qualified_v322(uuid,uuid,uuid,uuid,integer,uuid,timestamptz,uuid)',
       'execute') then
    raise exception 'v322: ACL floor is not held on the new functions' using errcode = '23514';
  end if;

  raise notice
    'v322 verified: referral pays points into the one active accruing programme and writes no '
    'credit; the W5 earn loop, arbiter and parity check are untouched; the R2/R3 exclusivity guard '
    'is at set_programmes_v314 and computed on the merged result so a partial R6 payload is judged '
    'correctly; referral is orthogonal to it; both referral writers installed; both detectors '
    'empty.';
end
$v322_post$;

commit;
