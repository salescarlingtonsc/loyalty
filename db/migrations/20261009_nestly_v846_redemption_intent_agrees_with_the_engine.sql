-- NESTLY v846 — the customer's QR and the counter that scans it read the same catalogue.
--
-- FOUR authorities decide whether a gift may be claimed, and in what order they speak:
--
--   * app.reward_availability_v432                  — what the customer is SHOWN
--   * public.customer_create_redemption_intent_v89  — what the customer's QR is MINTED from
--   * public.merchant_scan_redemption_qr_v117       — what the till ACCEPTS when the QR is scanned
--   * app.redeem_reward_core                        — what the counter actually PAYS OUT
--
-- The 2026-09-09 audit of the minter found FOUR places where it asks a different question from
-- its neighbours. All four were measured against PRODUCTION inside rolled-back transactions.
-- This migration closes all four, and it owns BOTH functions the fix needs — the minter and the
-- scanner — so the two halves land in ONE transaction rather than as two half-agreements.
--
-- THE RULE THIS FILE OBEYS. Ship a change that REMOVES a refusal and creates none. A change that
-- merely MOVES a refusal — from the counter to the tap, or from the tap to the counter — is not
-- shippable BY ITSELF; it is shippable together with the sibling that would otherwise disagree.
-- The previous revision of this file held (A) and (D) for exactly that reason and was right to,
-- because it did not own public.merchant_scan_redemption_qr_v117. It does now (no other migration
-- in this landing touches that function), so the correct move is no longer to hold: it is to land
-- both halves atomically, which is what the rule prescribes once both halves are in reach.
--
-- ============================================================================================
-- (A) THE PINNED VERSION — the minter. P1.
--
--     The version selector branched on the LIVE flag rather than on the shape of the programme:
--
--         config_version_id = case when v_reward.active
--               then businesses.active_config_version_id
--               else app.stamp_cycle_version_v416(business, client, programme) end
--
--     nestly_v805 (DELETE) sets loyalty_rewards.active = false, so a withdrawn stamp gift fell
--     through to the customer's PINNED cycle version — correct by accident. nestly_v814 (PAUSE)
--     deliberately leaves active = true ("a pause is not a delete", so the owner can un-pause), so
--     a paused-forward stamp gift took the OTHER branch, read the NEW paused version, and
--     app.reward_pause_on_offer_v814 returned false. Meanwhile app.reward_availability_v432 and
--     app.redeem_reward_core BOTH resolve a stamp reward through app.stamp_cycle_version_v416
--     regardless of that flag.
--
--       PRODUCTION, 2026-09-09, rolled back, a 4-of-5-stamp customer pinned to version 1, the
--       3-stamp gift paused forward (public.business_set_reward_paused_v326 -> version_forward,
--       live row still active=true):
--         reward_availability_v432 .......... available_at_counter
--         redeem_reward_core ................ ok=true, stamp_slot=3
--         customer_create_redemption_intent . 22023 "reward is unavailable"   <-- the odd one out
--
--     THE FIX. Ask the same question the other two ask: is this reward on this business's STAMPS
--     spine? If so, quote the version the customer's open card is pinned to; otherwise quote the
--     firm's active version. app.stamp_cycle_version_v416 already returns the active version when
--     nothing has been collected on the current card, so a stamps gift with no card open resolves
--     exactly where it did before. business_programmes carries one row per (business_id, kind), so
--     "the reward's programme is a stamps spine" and v432's "the reward's programme IS the stamps
--     spine" are the same predicate, not two that happen to agree today.
--
-- ============================================================================================
-- (D) THE QUOTED VERSION — the minter and the scanner. P1.
--
--     quoted_points_spent / quoted_reward_version_id / quoted_config_version_id were taken from
--     whatever version (A) resolved — the ACTIVE one — while app.redeem_reward_core charges the
--     PINNED one. Production, rolled back, gift edited from 3 stamps to 2 with the customer pinned
--     to version 1, driven through the real till scan: the intent quoted 2, the till printed 2,
--     and the ledger took 3. A number promised and not charged.
--
--     Correcting the minter alone was not enough, and that is why the previous revision held it.
--     public.merchant_scan_redemption_qr_v117, read from production on 2026-09-09, loaded the
--     quoted reward version with
--
--         and reward_version.config_version_id = business.active_config_version_id
--         and reward_version.active
--         ... if not found then raise exception 'catalog redemption terms changed; create a new QR'
--             using errcode = '23514';
--
--     so a correctly PINNED quote could not be scanned at all.
--
--     THIS IS NOT HYPOTHETICAL TODAY. v117's defect is ALREADY reachable in production with no
--     change to the minter: the minter's old `else` branch — a nestly_v805 WITHDRAWN stamp gift —
--     already quotes the PINNED version, and app.reward_live_on_offer_v805 keeps such a gift on
--     offer to a customer mid-card. Measured on production, 2026-09-09, rolled back:
--         reward_availability_v432 on the withdrawn gift ... available_at_counter
--         customer_create_redemption_intent ............... MINTED, quoting PINNED v1, points = 2
--         merchant_scan_redemption_qr_v117 ................ 23514 "catalog redemption terms
--                                                            changed; create a new QR"
--     A QR the product minted and the counter would not honour, in front of the customer, at the
--     point of payment. So this half closes a live path, not only the one (A) would have created.
--
--     THE FIX. Teach v117 to accept a quote pinned to the customer's stamp-cycle version FOR A
--     STAMPS REWARD, resolved exactly the way the minter now resolves it. It keeps accepting the
--     active version as well, deliberately: dropping that would refuse any QR minted before this
--     migration lands (production held 0 live pending intents at the time of writing, but the rule
--     is "creates no refusal", not "creates no refusal that anyone is standing in"), and after the
--     minter fix a stamps quote carries the pin anyway. For a NON-stamps reward nothing widens at
--     all — v_stamps_reward is false and the predicate collapses to the one that is there today.
--
--     WHAT DOES NOT CHANGE IN v117, and is carried through by construction because this is an
--     extract-and-diff of the live body rather than a restatement: the advisory lock, the
--     completed/replay contract, the pending check, intent expiry, the platform feature flag, the
--     per-business capability and module gates, the branch existence / branch-scope / write
--     permission checks, the loyalty_reward_services and loyalty_reward_products restrictions, the
--     loyalty_reward_branches eligibility check, the `reward_version.active` requirement, the
--     quote re-check against v_intent.quoted_terms, and the canonical operation/provenance fences.
--     The ONLY thing that changes is WHICH configuration version a STAMPS quote may carry.
--
--     PROVEN, production, 2026-09-09, rolled back, both splices applied inside the transaction,
--     one tenant, a 4-of-5-stamp customer pinned to version 1:
--       paused-forward gift  v432 available_at_counter -> MINTED quoting PINNED v1, points = 3
--                            -> till SCANNED, status completed, printed 3, engine slot 3
--                            -> stamp_milestone_claims: slot = 3, config_version_id = PINNED v1
--       gift edited 2 -> 1   MINTED quoting PINNED v1, points = 2
--                            -> till printed 2, engine slot 2, claim slot 2  (was 2 / 3 before)
--     and the guard is intact: a NON-stamps quote whose version is no longer the active one is
--     still refused with 23514.
--
-- ============================================================================================
-- (B) POT SCOPE — the minter. P1. Two adjacent lines disagreed with each other:
--
--       v_balance := app.client_points_balance_v409(...)   -- scope-aware since nestly_v409
--       select sum(remaining) ... where programme_id = v_intent_programme  -- NOT scope-aware
--
--     nestly_v815 taught app.redeem_reward_core to spend across every pot when
--     app.programme_balance_scope_v312(business) <> 'programme_pot' (the owner's ruling: under
--     business_pot the whole business pot is spendable). The minter was not moved with it.
--
--       PRODUCTION, rolled back, one pending programme_pot_migrations row, 70 live + 30 retired,
--       90-point gift:
--         programme_balance_scope_v312 ...... business_pot
--         client_points_balance_v409 ........ 100
--         reward_availability_v432 .......... available_at_counter
--         redeem_reward_core ................ ok=true, points_spent=90
--         customer_create_redemption_intent . 23514 "insufficient points"     <-- the odd one out
--
--     The fix mirrors v815's predicate exactly — `(v_all_pots or programme_id = v_intent_programme)`
--     with v_all_pots read once into a local, the way redeem_reward_core reads it, rather than
--     inlined into the WHERE clause where programme_balance_scope_v312 (which aggregates the whole
--     tenant's ledger and batches) would be re-evaluated per row. That is the nestly_v370 finding.
--
-- ============================================================================================
-- (C) EXPIRED POINTS COUNTED AS SPENDABLE — the minter. P2, latent.
--
--     The minter's batch sum carried no expiry filter, while app.customer_live_loyalty_v384 and
--     public.staff_get_customer_actionable_loyalty_v145 both exclude expired batches. The expiry
--     sweep runs once a day at 03:00 SGT, so a batch that expires at 10:00 stayed mintable for the
--     whole trading day.
--
--       PRODUCTION, rolled back, one batch of 100 that expired an hour ago, 50-point gift:
--         batch sum without an expiry filter (what the minter used) ... 100
--         batch sum with the v384/v145 filter ......................... 0
--         customer_live_loyalty_v384 balance shown to the customer .... 0
--         customer_create_redemption_intent ... MINTS a QR quoting 50 points
--
--     THE PREVIOUS REVISION HELD THIS, correctly, because a minter-only filter would refuse the
--     customer without closing the hole: app.reward_availability_v432 had no expiry filter either
--     (so the tile still said available_at_counter) and neither did app.redeem_reward_core (so the
--     staff-assisted path still spent the expired batch). That is no longer true.
--
--     *** APPLY WITH nestly_v847. *** The SIBLING migration in this same landing —
--     db/migrations/20261009_nestly_v847_redeem_engine_reversals_expiry_and_spine.sql, branch
--     claude/rewards-fix-engine — adds `(expires_at is null or expires_at > now())` to
--     app.reward_availability_v432's pot CTE and to app.redeem_reward_core's balance check, FEFO
--     drain loop and reconcile fence. v846 carries the minter's third of that predicate, verbatim.
--     The two migrations are applied together, minutes apart, by the orchestrator; applying v846
--     without v847 leaves the QR door shut while the catalogue tile and the staff-assisted path
--     stay open — a mis-shaped intermediate state, not a broken one, but not one to sit in.
--
--     Production on 2026-09-09 held ZERO points_batches rows with remaining > 0 and an expires_at
--     already in the past, across every tenant, so this defect is real in the code and empty in
--     the data on both sides of the fix. Nobody is standing in it while the pair lands.
--
-- ============================================================================================
-- EXPOSURE, production, 2026-09-09: 2 tenants with an active stamps spine, both with customer QR
-- redemption switched ON; 1 client already pinned to a configuration version other than the
-- active one; 0 paused-forward stamp gifts and 0 withdrawn stamp gifts right now (so (A) and (D)
-- are one owner keystroke away rather than live today); 0 expired-unswept points batches; 0 live
-- pending redemption intents, so this migration has no in-flight QR to invalidate.
--
-- ============================================================================================
-- KNOWN-OPEN, NOT MADE WORSE, recorded so it is not re-derived. app.redeem_reward_core has a THIRD
-- resolution the minter and the scanner do not model: when the CURRENT card cannot claim a stamp
-- gift it falls back to a SURVIVOR cycle (nestly_v435) and charges that closed cycle's
-- config_version_id. A quote can therefore still differ from the payout in the survivor case. It
-- differed before this migration too (the quote was the ACTIVE version, which is no more likely to
-- be the survivor's than the pin is), so nothing here regresses it, and v117 is NOT widened to
-- accept survivor versions — widening the set of versions a QR may carry is exactly the kind of
-- change that must be measured, not assumed. It belongs to its own migration.
--
-- ============================================================================================
-- FORM. Extract-and-diff, not a restatement: each live definition is read with pg_get_functiondef,
-- comment-free anchors are each required to match EXACTLY ONCE, the replacements are spliced in,
-- the result is length-checked against "the live body plus exactly these deltas" and executed. If
-- production has drifted, this refuses rather than silently reverting somebody's work.
--
-- ACCEPTANCE: db/tests/v846_redemption_intent_agrees_with_the_engine.sql (and the identical
-- db/tests/executed/ copy). Replay: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v846

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1 · PRE-FLIGHT — both live bodies are the ones this migration was written against, and every
--     function the replacements call is present with the signature they call it by.
-- ============================================================================================
do $v846_pre$
declare
  v_def text;
  v_scan text;
  v_anchor_declare constant text :=
$anchor_declare$  v_stamp_cycle integer;
begin
$anchor_declare$;
  v_anchor_version constant text :=
$anchor_version$    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_reward.active
            then (select business.active_config_version_id from public.businesses business
                   where business.id=p_business)
            else app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id) end
      and reward_version.active;
$anchor_version$;
  v_anchor_balance constant text :=
$anchor_balance$  v_balance := app.client_points_balance_v409(p_business, v_client);
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
$anchor_balance$;
  v_scan_declare constant text :=
$scan_declare$  v_customer_name text;
  v_reward_label text;
begin
$scan_declare$;
  v_scan_version constant text :=
$scan_version$    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and reward_version.config_version_id=business.active_config_version_id
       and reward_version.active
     for share;
$scan_version$;
begin
  if to_regprocedure('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)') is null then
    raise exception 'v846: public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text) is '
      'not present -- nestly_v89 and its successors must be applied first' using errcode = 'XX001';
  end if;
  if to_regprocedure('public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)') is null then
    raise exception 'v846: public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid) is not '
      'present -- nestly_v117 and its successors must be applied first' using errcode = 'XX001';
  end if;

  /* The replacements call these by exactly these signatures. A missing or re-signed helper would
     compile fine and fail at run time inside a customer's redemption or a counter's scan. */
  if to_regprocedure('app.programme_balance_scope_v312(uuid)') is null
     or to_regprocedure('app.client_points_balance_v409(uuid,uuid)') is null
     or to_regprocedure('app.stamp_cycle_version_v416(uuid,uuid,uuid)') is null
  then
    raise exception 'v846: a helper the spliced bodies call is missing or has been re-signed '
      '(programme_balance_scope_v312 / client_points_balance_v409 / stamp_cycle_version_v416)'
      using errcode = 'XX001';
  end if;

  v_def  := pg_get_functiondef(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);
  v_scan := pg_get_functiondef(
    'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)'::regprocedure);

  if position('v_all_pots' in v_def) > 0 and position('v_pinned_version' in v_scan) > 0 then
    raise notice 'v846: both functions already carry the v846 splices';
    return;
  end if;
  if (position('v_all_pots' in v_def) > 0) <> (position('v_pinned_version' in v_scan) > 0) then
    raise exception 'v846: exactly one of the two functions carries a v846 splice -- the pair was '
      'applied by halves, which is the one state this migration exists to prevent. Restore both '
      'from the pre-v846 definitions and re-apply.' using errcode = 'XX001';
  end if;

  if (length(v_def) - length(replace(v_def, v_anchor_declare, '')))
       / nullif(length(v_anchor_declare),0) <> 1
     or (length(v_def) - length(replace(v_def, v_anchor_version, '')))
       / nullif(length(v_anchor_version),0) <> 1
     or (length(v_def) - length(replace(v_def, v_anchor_balance, '')))
       / nullif(length(v_anchor_balance),0) <> 1 then
    raise exception 'v846: one of the three minter anchors did not match exactly once in '
      'public.customer_create_redemption_intent_v89 -- production has drifted; re-read '
      'pg_get_functiondef before splicing' using errcode = 'XX001';
  end if;
  if (length(v_scan) - length(replace(v_scan, v_scan_declare, '')))
       / nullif(length(v_scan_declare),0) <> 1
     or (length(v_scan) - length(replace(v_scan, v_scan_version, '')))
       / nullif(length(v_scan_version),0) <> 1 then
    raise exception 'v846: one of the two scanner anchors did not match exactly once in '
      'public.merchant_scan_redemption_qr_v117 -- production has drifted' using errcode = 'XX001';
  end if;

  /* The refusals these splices must NOT disturb. They are carried through untouched by
     construction (extract-and-diff), so if any of them is already absent the body is not the one
     v846 read and the splice would be reasoning about the wrong function. */
  if position('customer QR redemption is unavailable' in v_def) = 0
     or position('verified customer link required' in v_def) = 0
     or position('context-restricted rewards require staff-assisted redemption' in v_def) = 0
     or position('reward usage limit reached' in v_def) = 0
     or position('this stamp gift has already been claimed on this card' in v_def) = 0
     or position('idempotency key conflicts with another redemption intent' in v_def) = 0
     or position('reward_availability_v432' in v_def) = 0
  then
    raise exception 'v846: public.customer_create_redemption_intent_v89 is missing one of the '
      'refusals v846 carries forward -- refusing to splice a body it does not recognise'
      using errcode = 'XX001';
  end if;
  if position('pg_advisory_xact_lock' in v_scan) = 0
     or position('merchant loyalty redemption access is required' in v_scan) = 0
     or position('an active business branch is required' in v_scan) = 0
     or position('redemption branch scope is not permitted' in v_scan) = 0
     or position('redemption QR is no longer pending' in v_scan) = 0
     or position('intent_expired' in v_scan) = 0
     or position('scan_replayed' in v_scan) = 0
     or position('reward is not eligible at this branch' in v_scan) = 0
     or position('catalog redemption terms changed; create a new QR' in v_scan) = 0
     or position('canonical redemption operation was not recorded' in v_scan) = 0
  then
    raise exception 'v846: public.merchant_scan_redemption_qr_v117 is missing one of the guards '
      'v846 carries forward (lock / permission / branch / replay / expiry / quote re-check / '
      'provenance) -- refusing to splice a body it does not recognise' using errcode = 'XX001';
  end if;
end
$v846_pre$;

-- ============================================================================================
-- 2 · SPLICE A — THE MINTER. One extraction, three replacements, one CREATE OR REPLACE.
--
--     (i)   two locals declared beside the other scalars rather than computed inline. Both
--           app.programme_balance_scope_v312 and app.stamp_cycle_version_v416 aggregate over the
--           tenant's ledger; inlining either into a WHERE clause would re-evaluate it per row
--           (nestly_v370).
--     (ii)  (A)/(D) the version selector asks "is this a stamps reward?", the same question
--           app.reward_availability_v432 and app.redeem_reward_core ask, instead of reading
--           loyalty_rewards.active — which nestly_v814's pause deliberately leaves true.
--     (iii) (B) the batch sum takes nestly_v815's pot rule verbatim, and (C) the expiry predicate
--           nestly_v847 puts into app.reward_availability_v432 and app.redeem_reward_core.
-- ============================================================================================
do $v846_splice_minter$
declare
  v_def text;
  v_new text;
  v_anchor_declare constant text :=
$anchor_declare$  v_stamp_cycle integer;
begin
$anchor_declare$;
  v_inject_declare constant text :=
$inject_declare$  v_stamp_cycle integer;
  v_all_pots boolean := false;
  v_stamps_reward boolean := false;
begin
$inject_declare$;
  v_anchor_version constant text :=
$anchor_version$    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_reward.active
            then (select business.active_config_version_id from public.businesses business
                   where business.id=p_business)
            else app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id) end
      and reward_version.active;
$anchor_version$;
  v_inject_version constant text :=
$inject_version$    v_stamps_reward := exists (select 1 from public.business_programmes spine
                                where spine.id=v_reward.programme_id
                                  and spine.business_id=p_business and spine.kind='stamps');
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id = case when v_stamps_reward
            then app.stamp_cycle_version_v416(p_business, v_client, v_reward.programme_id)
            else (select business.active_config_version_id from public.businesses business
                   where business.id=p_business) end
      and reward_version.active;
$inject_version$;
  v_anchor_balance constant text :=
$anchor_balance$  v_balance := app.client_points_balance_v409(p_business, v_client);
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
$anchor_balance$;
  v_inject_balance constant text :=
$inject_balance$  v_balance := app.client_points_balance_v409(p_business, v_client);
  v_all_pots := app.programme_balance_scope_v312(p_business) <> 'programme_pot';
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and (expires_at is null or expires_at>now())
      and (v_all_pots or programme_id=v_intent_programme);
$inject_balance$;
begin
  v_def := pg_get_functiondef(
    'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure);

  if position('v_all_pots' in v_def) > 0 then
    raise notice 'v846: the minter splice is already applied, skipping';
    return;
  end if;

  v_new := replace(v_def, v_anchor_declare, v_inject_declare);
  v_new := replace(v_new, v_anchor_version, v_inject_version);
  v_new := replace(v_new, v_anchor_balance, v_inject_balance);

  /* Each anchor is gone and each injection is present exactly once. A replace() that silently
     matched nothing returns its input unchanged, which would ship an unfixed body under a
     migration that claims to have fixed it. */
  if position(v_anchor_declare in v_new) > 0
     or position(v_anchor_version in v_new) > 0
     or position(v_anchor_balance in v_new) > 0 then
    raise exception 'v846: a minter anchor survived the splice' using errcode = 'XX001';
  end if;
  if (length(v_new) - length(replace(v_new, v_inject_declare, '')))
       / nullif(length(v_inject_declare),0) <> 1
     or (length(v_new) - length(replace(v_new, v_inject_version, '')))
       / nullif(length(v_inject_version),0) <> 1
     or (length(v_new) - length(replace(v_new, v_inject_balance, '')))
       / nullif(length(v_inject_balance),0) <> 1 then
    raise exception 'v846: a minter injection is not present exactly once after the splice'
      using errcode = 'XX001';
  end if;
  /* And nothing else moved: the spliced text is the live text plus exactly the three deltas. */
  if length(v_new) <> length(v_def)
       - length(v_anchor_declare) - length(v_anchor_version) - length(v_anchor_balance)
       + length(v_inject_declare) + length(v_inject_version) + length(v_inject_balance) then
    raise exception 'v846: the spliced minter is not the live body plus exactly the three deltas'
      using errcode = 'XX001';
  end if;

  execute v_new;
end
$v846_splice_minter$;

-- ============================================================================================
-- 3 · SPLICE B — THE SCANNER. One extraction, two replacements, one CREATE OR REPLACE.
--
--     The stamps-ness of the reward and the customer's pinned version are resolved ONCE into
--     locals before the lookup, for the nestly_v370 reason above and because the lookup runs
--     FOR SHARE. The accepted set widens from {active version} to {active version, pinned
--     version} and ONLY for a reward whose programme is this business's stamps spine; for every
--     other reward v_stamps_reward is false and the predicate is the one that is live today.
--     `reward_version.active`, the id/reward/business identity checks, and every other guard in
--     this function are untouched.
-- ============================================================================================
do $v846_splice_scanner$
declare
  v_def text;
  v_new text;
  v_anchor_declare constant text :=
$scan_declare$  v_customer_name text;
  v_reward_label text;
begin
$scan_declare$;
  v_inject_declare constant text :=
$scan_inject_declare$  v_customer_name text;
  v_reward_label text;
  v_stamps_reward boolean := false;
  v_reward_programme uuid;
  v_pinned_version uuid;
begin
$scan_inject_declare$;
  v_anchor_version constant text :=
$scan_version$    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and reward_version.config_version_id=business.active_config_version_id
       and reward_version.active
     for share;
$scan_version$;
  v_inject_version constant text :=
$scan_inject_version$    select exists (select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.business_id=p_business
                      and spine.kind='stamps'),
           reward.programme_id
      into v_stamps_reward, v_reward_programme
      from public.loyalty_rewards reward
     where reward.id=v_intent.reward_id and reward.business_id=p_business;
    v_stamps_reward := coalesce(v_stamps_reward,false);
    if v_stamps_reward then
      v_pinned_version := app.stamp_cycle_version_v416(p_business, v_intent.client_id,
                                                       v_reward_programme);
    end if;
    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and (reward_version.config_version_id=business.active_config_version_id
            or (v_stamps_reward and v_pinned_version is not null
                and reward_version.config_version_id=v_pinned_version))
       and reward_version.active
     for share;
$scan_inject_version$;
begin
  v_def := pg_get_functiondef(
    'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)'::regprocedure);

  if position('v_pinned_version' in v_def) > 0 then
    raise notice 'v846: the scanner splice is already applied, skipping';
    return;
  end if;

  v_new := replace(v_def, v_anchor_declare, v_inject_declare);
  v_new := replace(v_new, v_anchor_version, v_inject_version);

  if position(v_anchor_declare in v_new) > 0
     or position(v_anchor_version in v_new) > 0 then
    raise exception 'v846: a scanner anchor survived the splice' using errcode = 'XX001';
  end if;
  if (length(v_new) - length(replace(v_new, v_inject_declare, '')))
       / nullif(length(v_inject_declare),0) <> 1
     or (length(v_new) - length(replace(v_new, v_inject_version, '')))
       / nullif(length(v_inject_version),0) <> 1 then
    raise exception 'v846: a scanner injection is not present exactly once after the splice'
      using errcode = 'XX001';
  end if;
  if length(v_new) <> length(v_def)
       - length(v_anchor_declare) - length(v_anchor_version)
       + length(v_inject_declare) + length(v_inject_version) then
    raise exception 'v846: the spliced scanner is not the live body plus exactly the two deltas'
      using errcode = 'XX001';
  end if;

  execute v_new;
end
$v846_splice_scanner$;

-- ============================================================================================
-- 4 · ACLs restated, not assumed. A same-signature CREATE OR REPLACE keeps the existing ACL, but
--     that is a property of the server, not a promise of this file. Live production ACL before
--     this migration, for BOTH functions:
--       {postgres=X/postgres, service_role=X/postgres, authenticated=X/postgres}
--     — the customer's own session mints its own QR, the counter's own session scans it, and
--     nothing anonymous may do either.
-- ============================================================================================
revoke all on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  from public, anon;
grant execute on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  to authenticated, service_role;
revoke all on function public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)
  from public, anon;
grant execute on function public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)
  to authenticated, service_role;

do $v846_acl$
begin
  if pg_catalog.has_function_privilege('anon',
       'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)', 'execute') then
    raise exception 'v846: anon can mint a redemption QR' using errcode = 'XX001';
  end if;
  if pg_catalog.has_function_privilege('anon',
       'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)', 'execute') then
    raise exception 'v846: anon can scan a redemption QR' using errcode = 'XX001';
  end if;
  if not pg_catalog.has_function_privilege('authenticated',
       'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)', 'execute')
     or not pg_catalog.has_function_privilege('service_role',
       'public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)', 'execute') then
    raise exception 'v846: the customer''s own role lost execute on the QR minter'
      using errcode = 'XX001';
  end if;
  if not pg_catalog.has_function_privilege('authenticated',
       'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)', 'execute')
     or not pg_catalog.has_function_privilege('service_role',
       'public.merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)', 'execute') then
    raise exception 'v846: the counter''s own role lost execute on the QR scanner'
      using errcode = 'XX001';
  end if;
end
$v846_acl$;

-- ============================================================================================
-- 5 · IN-TRANSACTION VERIFICATION — behaviour, not source text.
--
--     TWO synthetic tenants:
--       * a POINTS firm with a live pot and a retired pot — (B) and (C), plus the control that
--         the ordinary non-stamps path still mints, still scans, and still refuses a quote that
--         is no longer the active configuration version;
--       * a STAMPS firm with a customer four stamps into a five-stamp card — (A) and (D), driven
--         end to end through the real minter and the real till scanner.
--
--     All of it lives in a PL/pgSQL SUB-TRANSACTION that is ALWAYS rolled back by raising the
--     P0846 sentinel after the last assertion. This is safety, not tidiness: the fixtures publish
--     configuration versions, mint QRs, scan them and write ledger rows through triggers, and
--     deleting them afterwards could not prove it had caught everything. A real assertion failure
--     raises P0001, is NOT caught, and aborts the migration.
-- ============================================================================================
do $v846_verify$
declare
  p_biz uuid := gen_random_uuid();
  p_owner uuid := gen_random_uuid();
  p_cust uuid := gen_random_uuid();
  p_identity uuid := gen_random_uuid();
  p_c1 uuid := gen_random_uuid();
  p_live uuid; p_retired uuid;
  p_branch uuid := gen_random_uuid();
  p_staff uuid;
  p_gift90 uuid := gen_random_uuid();
  p_gift50 uuid := gen_random_uuid();
  p_link uuid := gen_random_uuid();
  p_s1 uuid := gen_random_uuid();
  p_s2 uuid := gen_random_uuid();
  p_cfg uuid; p_cfg_draft uuid;
  p_migration uuid := gen_random_uuid();
  p_batch_live uuid;
  s_biz uuid := gen_random_uuid();
  s_owner uuid := gen_random_uuid();
  s_cust uuid := gen_random_uuid();
  s_identity uuid := gen_random_uuid();
  s_client uuid := gen_random_uuid();
  s_spine uuid := gen_random_uuid();
  s_branch uuid := gen_random_uuid();
  s_staff uuid;
  s_link uuid := gen_random_uuid();
  s_seed uuid := gen_random_uuid();
  s_two uuid := gen_random_uuid();
  s_free uuid := gen_random_uuid();
  s_big uuid := gen_random_uuid();
  s_cfg uuid; s_cfg2 uuid;
  v_res jsonb; v_txt text; v_err text; v_msg text; v_intent jsonb; v_iid uuid;
  b_users bigint; b_biz bigint; b_intents bigint; b_ledger bigint; b_batches bigint;
  b_cfgs bigint; b_potmig bigint; b_redeem bigint; b_claims bigint; b_ops bigint;
  a_users bigint; a_biz bigint; a_intents bigint; a_ledger bigint; a_batches bigint;
  a_cfgs bigint; a_potmig bigint; a_redeem bigint; a_claims bigint; a_ops bigint;
begin
  /* Captured OUTSIDE the sub-transaction, so the leak check measures against the production state
     this migration found. */
  select count(*) into b_users   from auth.users;
  select count(*) into b_biz     from public.businesses;
  select count(*) into b_intents from public.customer_redemption_intents_v89;
  select count(*) into b_ledger  from public.points_ledger;
  select count(*) into b_batches from public.points_batches;
  select count(*) into b_cfgs    from public.firm_config_versions;
  select count(*) into b_potmig  from public.programme_pot_migrations;
  select count(*) into b_redeem  from public.loyalty_redemptions;
  select count(*) into b_claims  from public.stamp_milestone_claims;
  select count(*) into b_ops     from public.loyalty_operations;

  begin
    -- ========================================================================================
    -- TENANT ONE — a points firm: 70 in the pot the gift belongs to, 30 in the pot being
    -- migrated away from, a 90-point gift that needs both and a 50-point gift that does not.
    -- ========================================================================================
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
            'zz-v846-po-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
           ('00000000-0000-0000-0000-000000000000',p_cust,'authenticated','authenticated',
            'zz-v846-pc-'||substr(p_cust::text,1,8)||'@example.test','',now(),now(),now());
    perform set_config('app.v79_system_transition','on',true);
    insert into public.businesses(id,name,slug,enabled_modules,points_mode)
    values (p_biz,'V846 Points Firm','zz-v846p-'||substr(p_biz::text,1,8),array['loyalty'],'redeem');
    perform set_config('app.v79_system_transition','',true);
    select id into p_live    from public.business_programmes where business_id=p_biz and kind='points';
    select id into p_retired from public.business_programmes where business_id=p_biz and kind='stamps';
    update public.business_programmes set active=true  where id=p_live;
    update public.business_programmes set active=false where id=p_retired;
    insert into public.staff(business_id,user_id,role,active,access_state)
    values (p_biz,p_owner,'owner',true,'approved') returning id into p_staff;
    insert into public.branches(id,business_id,name,is_default,active)
    values (p_branch,p_biz,'V846 points main',true,true);
    insert into public.staff_branches(business_id,staff_id,branch_id)
    values (p_biz,p_staff,p_branch);
    update public.business_workspace_controls_v94
       set approval_status='approved',version=version+1,decided_by=p_owner,
           decided_at=clock_timestamp(),decision_reason='v846 verification fixture',
           updated_at=clock_timestamp()
     where business_id=p_biz;
    insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
    values (p_biz,false) on conflict (business_id) do update set workspace_paused=false;
    insert into public.subscriptions(business_id) values (p_biz) on conflict do nothing;
    insert into app.platform_feature_flags(feature_key,enabled)
    values ('customer_wallet',true),('customer_claims',true),('customer_qr_redemption',true)
    on conflict (feature_key) do update set enabled=true;
    insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
    values (p_biz,true) on conflict (business_id) do update set redemption_enabled=true;
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                        configuration_status,earn_points_per_dollar)
    values (p_biz,true,'points_tiers','points','published',1)
    on conflict (business_id) do update
      set active=true,loyalty_model='points_tiers',kind='points',configuration_status='published';
    select id into p_cfg from public.firm_config_versions
     where business_id=p_biz and status='published' order by version_no desc limit 1;
    if p_cfg is null then
      raise exception 'v846 verify: the points fixture published no configuration version';
    end if;
    update public.businesses set active_config_version_id=p_cfg where id=p_biz;
    insert into public.clients(id,business_id,full_name,phone)
    values (p_c1,p_biz,'V846 Two Pots','+65 9832 0001');
    insert into public.customer_identities(id,auth_user_id,status)
    values (p_identity,p_cust,'active');
    perform set_config('app.customer_link_insert_id',p_link::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                      verification_method,verified_at)
    values (p_link,p_biz,p_identity,p_cust,p_c1,'verified','phone_claim',now());
    perform set_config('app.customer_link_insert_id','',true);
    insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
    values (p_gift90,p_biz,'V846 Big 90','V846 Big 90','V846 Big 90','manual_item',90,0,0,true,false,1,p_live),
           (p_gift50,p_biz,'V846 Mid 50','V846 Mid 50','V846 Mid 50','manual_item',50,0,0,true,false,2,p_live);
    insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,
      internal_name,customer_name,description,fulfillment_kind,cost_points,credit_cents,
      estimated_cost_cents,sort,programme_id)
    values (p_gift90,p_biz,p_cfg,'V846 Big 90','V846 Big 90','crosses the pots','manual_item',90,0,0,1,p_live),
           (p_gift50,p_biz,p_cfg,'V846 Mid 50','V846 Mid 50','fits one pot'    ,'manual_item',50,0,0,2,p_live);
    perform app.acquire_loyalty_shared_v480(p_biz);
    perform set_config('app.points_ledger_insert_id',p_s1::text,true);
    perform set_config('app.points_ledger_write_scope','adjust_points',true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                     programme_id)
    values (p_s1,p_biz,p_c1,'adjust',70,'v846 live pot',p_owner,p_live);
    perform set_config('app.points_ledger_insert_id',p_s2::text,true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                     programme_id)
    values (p_s2,p_biz,p_c1,'adjust',30,'v846 retired pot',p_owner,p_retired);
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);
    /* The batch must match the ledger pot for pot: a pot whose ledger sum and batch remaining
       disagree is itself a business_pot trigger in app.programme_balance_scope_v312, which would
       make the programme_pot half of this verification unreachable. */
    insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
    values (p_biz,p_c1,p_live   , 70, 70,now()+interval '90 days')
    returning id into p_batch_live;
    insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,expires_at)
    values (p_biz,p_c1,p_retired, 30, 30,now()+interval '10 days');

    -- ---- B. Pot scope: one pending migration row and the whole business pot is spendable.
    insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,
                                                status)
    values (p_migration,p_biz,p_retired,p_live,'pending');
    if app.programme_balance_scope_v312(p_biz) is distinct from 'business_pot' then
      raise exception 'v846 verify: the pending pot migration did not put the firm in business_pot';
    end if;
    if app.client_points_balance_v409(p_biz,p_c1) is distinct from 100 then
      raise exception 'v846 verify: the scope-aware balance is %, expected 100 (70 live + 30 '
        'retired)', app.client_points_balance_v409(p_biz,p_c1);
    end if;
    select ra.availability into v_txt
      from app.reward_availability_v432(p_biz,p_c1) ra where ra.reward_id=p_gift90;
    if coalesce(v_txt,'ABSENT') is distinct from 'available_at_counter' then
      raise exception 'v846 verify: the availability core does not offer the cross-pot gift (%), '
        'so the disagreement this asserts is not reproduced', coalesce(v_txt,'ABSENT');
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null;
    begin
      perform public.customer_create_redemption_intent_v89(p_biz,p_gift90,gen_random_uuid(),
                'catalog_reward');
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    if v_err is not null then
      raise exception 'v846 verify: (B) under business_pot the minter still refuses a gift the '
        'wallet, app.reward_availability_v432 and app.redeem_reward_core all call affordable: % %',
        v_err, v_msg;
    end if;
    /* The counter, on the same fixture: nestly_v815's drain really does cross the pots. */
    v_res := app.redeem_reward_core(p_biz,p_c1,p_gift90,'v846-verify-core-02',p_branch)::jsonb;
    if not coalesce((v_res->>'ok')::boolean,false) then
      raise exception 'v846 verify: (B) app.redeem_reward_core refused the cross-pot gift the '
        'minter just quoted: %', v_res;
    end if;

    -- ---- B sensitivity. The fix is not "always sum every pot".
    perform public.reverse_loyalty_redemption(p_biz,(v_res->>'redemption_id')::uuid,
      'v846 verification: restore the pots before the programme_pot control',
      'v846-verify-rev-02');
    delete from public.programme_pot_migrations where id = p_migration;
    if app.programme_balance_scope_v312(p_biz) is distinct from 'programme_pot' then
      raise exception 'v846 verify: removing the pot migration did not restore programme_pot';
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null;
    begin
      perform public.customer_create_redemption_intent_v89(p_biz,p_gift90,gen_random_uuid(),
                'catalog_reward');
    exception when others then v_err := sqlstate;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    if v_err is null then
      raise exception 'v846 verify: back in programme_pot scope the minter still spent the other '
        'pot -- the scope rule was dropped rather than mirrored';
    end if;

    -- ---- CONTROL. The ordinary non-stamps path is untouched end to end: a 50-point gift the
    --      live pot can afford mints from the ACTIVE version and the real till completes it.
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null; v_intent := null;
    begin
      v_intent := public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),
                    'catalog_reward');
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    if v_err is not null then
      raise exception 'v846 verify: under programme_pot a 50-point gift on a 70-point live pot was '
        'refused (% %) -- the splice broke the ordinary single-pot path', v_err, v_msg;
    end if;
    v_iid := (v_intent->>'intent_id')::uuid;
    if (select i.quoted_config_version_id from public.customer_redemption_intents_v89 i
         where i.id=v_iid) is distinct from p_cfg then
      raise exception 'v846 verify: a POINTS gift was not quoted from the active configuration '
        'version -- the stamps branch is leaking into the non-stamps path';
    end if;
    v_res := public.merchant_scan_redemption_qr_v117(p_biz,p_branch,v_intent->>'qr_token',
               gen_random_uuid());
    if coalesce(v_res->>'status','') is distinct from 'completed'
       or coalesce((v_res->>'points_spent')::integer,-1) <> 50 then
      raise exception 'v846 verify: the till did not complete an ordinary points redemption: %',
        v_res;
    end if;
    /* That scan really spent 50 of the live pot's 70. Put them back, or the expiry assertions
       below would refuse for want of points rather than for want of unexpired ones. */
    perform public.reverse_loyalty_redemption(p_biz,(v_res->>'redemption_id')::uuid,
      'v846 verification: restore the live pot before the expiry assertions','v846-verify-rev-03');

    -- ---- GUARD. A NON-stamps quote whose version is no longer the active one is still refused.
    --      This is the refusal the scanner splice must not have weakened.
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_intent := public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),
                  'catalog_reward');
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    insert into public.firm_config_versions(business_id,version_no,status,snapshot_hash)
    values (p_biz,9846,'draft',md5('v846-verify')) returning id into p_cfg_draft;
    update public.businesses set active_config_version_id=p_cfg_draft where id=p_biz;
    v_err := null;
    begin
      perform public.merchant_scan_redemption_qr_v117(p_biz,p_branch,v_intent->>'qr_token',
                gen_random_uuid());
    exception when others then v_err := sqlstate;
    end;
    if v_err is distinct from '23514' then
      raise exception 'v846 verify: a non-stamps quote on a superseded configuration version was '
        'no longer refused (sqlstate %) -- the scanner splice weakened the terms-changed guard',
        coalesce(v_err,'ACCEPTED');
    end if;
    update public.businesses set active_config_version_id=p_cfg where id=p_biz;

    -- ---- C. Expired points are no longer mintable, and the filter is not "refuse everything".
    update public.points_batches set expires_at=now()-interval '1 hour' where id=p_batch_live;
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null;
    begin
      perform public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),
                'catalog_reward');
    exception when others then v_err := sqlstate;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    if v_err is distinct from '23514' then
      raise exception 'v846 verify: (C) a batch that expired an hour ago is still spendable by '
        'the minter (sqlstate %)', coalesce(v_err,'MINTED');
    end if;
    update public.points_batches set expires_at=now()+interval '1 hour' where id=p_batch_live;
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null;
    begin
      perform public.customer_create_redemption_intent_v89(p_biz,p_gift50,gen_random_uuid(),
                'catalog_reward');
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',p_owner,'role','authenticated')::text,true);
    if v_err is not null then
      raise exception 'v846 verify: (C) the same batch with an hour of life left was refused '
        '(% %) -- the expiry filter refuses live points', v_err, v_msg;
    end if;

    -- ========================================================================================
    -- TENANT TWO — a stamps firm: one customer four stamps into a five-stamp card, pinned to
    -- configuration version 1, and the gift at stamp 3 paused FORWARD the nestly_v814 way.
    -- Version 1 is backdated two days and version 2 an hour, so app.stamp_cycle_version_v416
    -- ("the newest version published at or before this customer's first stamp") has a strict
    -- ordering rather than a coin toss between two rows with the same published_at.
    -- ========================================================================================
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',s_owner,'authenticated','authenticated',
            'zz-v846-so-'||substr(s_owner::text,1,8)||'@example.test','',now(),now(),now()),
           ('00000000-0000-0000-0000-000000000000',s_cust,'authenticated','authenticated',
            'zz-v846-sc-'||substr(s_cust::text,1,8)||'@example.test','',now(),now(),now());
    perform set_config('app.v79_system_transition','on',true);
    insert into public.businesses(id,name,slug,enabled_modules,points_mode)
    values (s_biz,'V846 Stamp Kopi','zz-v846s-'||substr(s_biz::text,1,8),array['loyalty'],'redeem');
    perform set_config('app.v79_system_transition','',true);
    insert into public.business_programmes(id,business_id,kind,active,sort)
    values (s_spine,s_biz,'stamps',true,3)
    on conflict (business_id,kind) do update set active=true
    returning id into s_spine;
    update public.business_programmes set active=true where business_id=s_biz and kind='points';
    insert into public.staff(business_id,user_id,role,active,access_state)
    values (s_biz,s_owner,'owner',true,'approved') returning id into s_staff;
    insert into public.branches(id,business_id,name,is_default,active)
    values (s_branch,s_biz,'V846 stamps main',true,true);
    insert into public.staff_branches(business_id,staff_id,branch_id)
    values (s_biz,s_staff,s_branch);
    update public.business_workspace_controls_v94
       set approval_status='approved',version=version+1,decided_by=s_owner,
           decided_at=clock_timestamp(),decision_reason='v846 verification fixture',
           updated_at=clock_timestamp()
     where business_id=s_biz;
    insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
    values (s_biz,false) on conflict (business_id) do update set workspace_paused=false;
    insert into public.subscriptions(business_id) values (s_biz) on conflict do nothing;
    insert into public.business_customer_capabilities_v89(business_id,redemption_enabled)
    values (s_biz,true) on conflict (business_id) do update set redemption_enabled=true;
    perform set_config('request.jwt.claims',
      json_build_object('sub',s_owner,'role','authenticated')::text,true);
    insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                        configuration_status,stamp_target,stamp_per_cents)
    values (s_biz,true,'stamps','stamps','published',5,500)
    on conflict (business_id) do update
      set active=true,loyalty_model='stamps',kind='stamps',configuration_status='published',
          stamp_target=5,stamp_per_cents=500;
    select id into s_cfg from public.firm_config_versions
     where business_id=s_biz and status='published' order by version_no desc limit 1;
    if s_cfg is null then
      raise exception 'v846 verify: the stamps fixture published no configuration version';
    end if;
    update public.businesses set active_config_version_id=s_cfg where id=s_biz;
    update public.firm_config_versions set published_at=now()-interval '2 days' where id=s_cfg;
    insert into public.clients(id,business_id,full_name,phone)
    values (s_client,s_biz,'V846 Mid Card','+65 9832 1001');
    insert into public.customer_identities(id,auth_user_id,status)
    values (s_identity,s_cust,'active');
    perform set_config('app.customer_link_insert_id',s_link::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                      verification_method,verified_at)
    values (s_link,s_biz,s_identity,s_cust,s_client,'verified','phone_claim',now());
    perform set_config('app.customer_link_insert_id','',true);
    insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,
      fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active,paused,sort,programme_id)
    values (s_two ,s_biz,'V846 Kaya','V846 Kaya','V846 Kaya','manual_item',2,0,0,true,false,1,s_spine),
           (s_free,s_biz,'V846 Kopi','V846 Kopi','V846 Kopi','manual_item',3,0,0,true,false,2,s_spine),
           (s_big ,s_biz,'V846 Final','V846 Final','V846 Final','manual_item',5,0,0,true,false,3,s_spine);
    /* `paused` is deliberately not listed on the version rows: the nestly_v814 BEFORE INSERT
       default must inherit it from the live row. If that trigger were missing these would arrive
       NULL and the NOT NULL would fail here, in the fixture, rather than silently later. */
    insert into public.loyalty_reward_versions(reward_id,business_id,config_version_id,
      internal_name,customer_name,description,fulfillment_kind,cost_points,credit_cents,
      estimated_cost_cents,sort,programme_id)
    values (s_two ,s_biz,s_cfg,'V846 Kaya','V846 Kaya','stamp 2','manual_item',2,0,0,1,s_spine),
           (s_free,s_biz,s_cfg,'V846 Kopi','V846 Kopi','stamp 3','manual_item',3,0,0,2,s_spine),
           (s_big ,s_biz,s_cfg,'V846 Final','V846 Final','stamp 5','manual_item',5,0,0,3,s_spine);
    /* The EXCLUSIVE fence rather than the shared one every till write takes: this is a single
       transaction and app.acquire_loyalty_exclusive_v480, which publish_loyalty_config takes when
       the pause publishes, refuses to upgrade a fence already held shared. */
    perform app.acquire_loyalty_exclusive_v480(s_biz);
    perform set_config('app.points_ledger_insert_id',s_seed::text,true);
    perform set_config('app.points_ledger_write_scope','adjust_points',true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                     programme_id,created_at)
    values (s_seed,s_biz,s_client,'adjust',4,'v846 seed stamps',s_owner,s_spine,
            now()-interval '1 day');
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);
    insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
    values (s_biz,s_client,s_spine,4,4);

    if app.stamp_cycle_version_v416(s_biz,s_client,s_spine) is distinct from s_cfg then
      raise exception 'v846 verify: the stamps fixture customer is not pinned to version 1';
    end if;

    -- ---- A. Pause the stamp-3 gift FORWARD. nestly_v814 leaves loyalty_rewards.active = true,
    --      which is exactly what the old version selector mistook for "quote the new version".
    v_res := public.business_set_reward_paused_v326(s_biz,s_free,true);
    if coalesce(v_res->>'mode','') is distinct from 'version_forward' then
      raise exception 'v846 verify: pausing the stamp gift did not version forward: %', v_res;
    end if;
    select active_config_version_id into s_cfg2 from public.businesses where id=s_biz;
    if s_cfg2 is null or s_cfg2 = s_cfg then
      raise exception 'v846 verify: the pause published no new configuration version';
    end if;
    update public.firm_config_versions set published_at=now()-interval '1 hour' where id=s_cfg2;
    if (select r.active from public.loyalty_rewards r where r.id=s_free) is distinct from true then
      raise exception 'v846 verify: the pause cleared loyalty_rewards.active -- the (A) scenario '
        'is not reproduced, because the old selector would have taken the pinned branch anyway';
    end if;
    if app.stamp_cycle_version_v416(s_biz,s_client,s_spine) is distinct from s_cfg then
      raise exception 'v846 verify: the publish moved the mid-card customer off version 1';
    end if;
    select ra.availability into v_txt
      from app.reward_availability_v432(s_biz,s_client) ra where ra.reward_id=s_free;
    if coalesce(v_txt,'ABSENT') is distinct from 'available_at_counter' then
      raise exception 'v846 verify: (A) the availability core does not offer the paused-forward '
        'gift (%), so the disagreement this asserts is not reproduced', coalesce(v_txt,'ABSENT');
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub',s_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null; v_intent := null;
    begin
      v_intent := public.customer_create_redemption_intent_v89(s_biz,s_free,gen_random_uuid(),
                    'catalog_reward');
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',s_owner,'role','authenticated')::text,true);
    if v_err is not null then
      raise exception 'v846 verify: (A) the minter still refuses a paused-forward stamp gift that '
        'app.reward_availability_v432 offers and app.redeem_reward_core would pay out: % %',
        v_err, v_msg;
    end if;
    v_iid := (v_intent->>'intent_id')::uuid;
    if (select i.quoted_config_version_id from public.customer_redemption_intents_v89 i
         where i.id=v_iid) is distinct from s_cfg then
      raise exception 'v846 verify: (A) the QR was minted from a version other than the one the '
        'customer''s open card is pinned to';
    end if;
    if (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
         where i.id=v_iid) is distinct from 3 then
      raise exception 'v846 verify: (A) the QR quoted % stamps, expected the pinned 3',
        (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
          where i.id=v_iid);
    end if;

    -- ---- D. And the counter accepts that pinned quote, prints it, and charges it.
    v_res := public.merchant_scan_redemption_qr_v117(s_biz,s_branch,v_intent->>'qr_token',
               gen_random_uuid());
    if coalesce(v_res->>'status','') is distinct from 'completed' then
      raise exception 'v846 verify: (D) the till refused the pinned quote it was just handed: %',
        v_res;
    end if;
    if coalesce((v_res->>'points_spent')::integer,-1) <> 3
       or coalesce((v_res->'result'->>'stamp_slot')::integer,-1) <> 3 then
      raise exception 'v846 verify: (D) the till printed % while the engine charged % -- promise '
        'and payout still disagree: %', v_res->>'points_spent',
        v_res->'result'->>'stamp_slot', v_res;
    end if;
    if not exists (select 1 from public.stamp_milestone_claims c
                    where c.business_id=s_biz and c.client_id=s_client and c.reward_id=s_free
                      and c.slot_position=3 and c.config_version_id=s_cfg) then
      raise exception 'v846 verify: (D) the ledger did not record the claim at the PINNED version '
        'and slot 3';
    end if;

    -- ---- D, the price case. Edit the stamp-2 gift down to stamp 1: the mid-card customer stays
    --      pinned, so quote, receipt and ledger must all read 2, not 1.
    v_res := public.business_update_reward_v326(s_biz,s_two,'V846 Kaya'::text,1,null::text,0,
               null::text,false,null::timestamptz,false,null::text,null::integer,false,
               null::integer);
    perform set_config('request.jwt.claims',
      json_build_object('sub',s_cust,'role','authenticated')::text,true);
    execute 'set local role authenticated';
    v_err := null; v_intent := null;
    begin
      v_intent := public.customer_create_redemption_intent_v89(s_biz,s_two,gen_random_uuid(),
                    'catalog_reward');
    exception when others then v_err := sqlstate; v_msg := sqlerrm;
    end;
    execute 'reset role';
    perform set_config('request.jwt.claims',
      json_build_object('sub',s_owner,'role','authenticated')::text,true);
    if v_err is not null then
      raise exception 'v846 verify: (D) the minter refused an edited-forward stamp gift the '
        'customer is still pinned to: % %', v_err, v_msg;
    end if;
    v_iid := (v_intent->>'intent_id')::uuid;
    if (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
         where i.id=v_iid) is distinct from 2 then
      raise exception 'v846 verify: (D) the edited gift was quoted at % rather than the pinned 2',
        (select i.quoted_points_spent from public.customer_redemption_intents_v89 i
          where i.id=v_iid);
    end if;
    v_res := public.merchant_scan_redemption_qr_v117(s_biz,s_branch,v_intent->>'qr_token',
               gen_random_uuid());
    if coalesce((v_res->>'points_spent')::integer,-1) <> 2
       or coalesce((v_res->'result'->>'stamp_slot')::integer,-1) <> 2
       or not exists (select 1 from public.stamp_milestone_claims c
                       where c.business_id=s_biz and c.client_id=s_client and c.reward_id=s_two
                         and c.slot_position=2) then
      raise exception 'v846 verify: (D) promised, printed and charged still disagree on the '
        'edited gift: %', v_res;
    end if;

    /* Every assertion passed. Throw both tenants away on purpose. */
    raise exception 'v846 verify: rollback sentinel' using errcode = 'P0846';
  exception
    when sqlstate 'P0846' then
      null;  -- expected: assertions all passed, fixtures rolled back
  end;

  select count(*) into a_users   from auth.users;
  select count(*) into a_biz     from public.businesses;
  select count(*) into a_intents from public.customer_redemption_intents_v89;
  select count(*) into a_ledger  from public.points_ledger;
  select count(*) into a_batches from public.points_batches;
  select count(*) into a_cfgs    from public.firm_config_versions;
  select count(*) into a_potmig  from public.programme_pot_migrations;
  select count(*) into a_redeem  from public.loyalty_redemptions;
  select count(*) into a_claims  from public.stamp_milestone_claims;
  select count(*) into a_ops     from public.loyalty_operations;
  if a_users <> b_users or a_biz <> b_biz or a_intents <> b_intents or a_ledger <> b_ledger
     or a_batches <> b_batches or a_cfgs <> b_cfgs or a_potmig <> b_potmig
     or a_redeem <> b_redeem or a_claims <> b_claims or a_ops <> b_ops then
    raise exception 'v846 verify: the verification block leaked rows into production '
      '(users %/%, businesses %/%, intents %/%, points_ledger %/%, points_batches %/%, '
      'config_versions %/%, pot_migrations %/%, redemptions %/%, milestone_claims %/%, '
      'loyalty_operations %/%)',
      b_users,a_users, b_biz,a_biz, b_intents,a_intents, b_ledger,a_ledger,
      b_batches,a_batches, b_cfgs,a_cfgs, b_potmig,a_potmig, b_redeem,a_redeem,
      b_claims,a_claims, b_ops,a_ops;
  end if;

  raise notice 'v846: the QR minter and the counter that scans it now read the same catalogue -- '
    'pot scope, the stamp-cycle pin and the expiry filter verified in a rolled-back '
    'sub-transaction; production state unchanged';
end
$v846_verify$;

commit;
