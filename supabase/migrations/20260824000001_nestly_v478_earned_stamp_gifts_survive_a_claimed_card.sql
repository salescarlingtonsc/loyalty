-- nestly_v478 — a gift you have already earned is not lost when the card closes.
--
-- OWNER, 2026-08-23: "when rewards are given as the stamp cards are filled > all unused rewards
-- will be sitting in customer's account, because now if there are 2 unused rewards, and customer
-- redeem just one of it - the other one will disappear as the new stamp cards refresh."
--
-- CONFIRMED AND REPRODUCED IN PRODUCTION. QA Kopi Lab (Bedok), client 07fd0757, card of 10 with
-- gifts on 2 / 4 / 10. They reached 10 stamps at 15:48:28 — all three earned. They claimed Lattee
-- (slot 2) and Free Kopi Set (slot 10). "Hava a cup of Milk Tea!" on slot 4 was earned and never
-- claimed, and at 15:48:43 — the instant of the final claim — it became unreachable. Before this
-- migration it read `insufficient_balance, remaining 2`: they must re-earn a gift they had
-- already fully earned.
--
-- THE MECHANISM. app.redeem_reward_core closes the card when the gift being claimed sits at or
-- past the LAST slot (`cost_points >= v_stamp_slots`), inserting a stamp_cycles row with
-- origin='claimed'. app.stamp_progress_v323 derives the card position arithmetically —
-- filled = net_stamps - sum(closed cycle slots) — so that insert subtracts a whole card's worth
-- in one statement, and every gift that was reachable a millisecond earlier stops being reachable.
--
-- An earned-but-unclaimed stamp gift is not stored anywhere. It is DERIVED: "filled >= cost_points
-- AND no claim row for this cycle". stamp_milestone_claims records only what WAS taken;
-- reward_grants and program_entitlements belong to the retention/campaign paths, not to stamps.
-- So collapsing `filled` IS the destruction. There is no row to lose because there was never a row.
--
-- WHY NO NEW TABLE. The survival machinery already exists and is proven — v435 built it, and its
-- own note says already-earned milestones survive and stay claimable at the counter. It was simply
-- gated on ONE origin. Three predicates said 'expired' where they meant "the card is over":
--   * app.reward_availability_v432's survival arm
--   * app.redeem_reward_core's own survival lookup (whose v_survival branch already skips the
--     stamp check AND suppresses a second cycle-close, so a survivor claim is already correct)
--   * app.stamp_reward_expire_due_v464's window, so survivors still honour the owner's per-gift
--     deadline instead of becoming immortal
-- A card that ended because it was completed is no less over than one that ended because it
-- lapsed. The arm's existing `rv.cost_points <= sc.slots` join is already exactly right for a
-- claimed cycle: everything on that card was, by construction, earned — the final claim required
-- filled >= slots. Its `not exists (claim)` filter already excludes what was taken.
--
-- Because every reader goes through reward_availability_v432 —
-- customer_get_reward_catalog, staff_get_customer_actionable_loyalty_v145,
-- customer_get_business_actions_v89, app.customer_ready_reward_count_v465 — this propagates
-- everywhere for free.
--
-- THE SECOND BUG, fixed here too. stamp_milestone_claims_slot_uk is UNIQUE
-- (business, client, programme, cycle_index, slot_position). Two gifts on the SAME slot are
-- therefore mutually exclusive per card — claiming one makes the other raise unique_violation,
-- reported to staff as the misleading "this stamp gift has already been claimed on this card".
-- Cubbly SPA has exactly that shape (two gifts both on slot 5 of a 5-slot card). It would also
-- block a survivor claim that reuses the closed cycle's slot number. Dropped. The correct rule —
-- one claim per GIFT per card — is stamp_milestone_claims_reward_uk, which is kept.
--
-- RETROACTIVE, DELIBERATELY. No data is migrated, but claimability is restored for gifts real
-- customers genuinely earned and lost. That is restitution, and it is precisely what the owner
-- asked for. Two limits still apply and are not bypassed: a gift's usage_limit still counts, so a
-- limit-1 gift already redeemed later reads limit_reached rather than becoming claimable again;
-- and a survivor whose owner-set deadline has already passed is swept to reward_expired by the
-- third predicate rather than silently claimable.
--
-- Verified before applying, rolled back: the QA Kopi Lab victim moves from
-- `insufficient_balance, remaining 2` to `available_at_counter, remaining 0`, while the gift they
-- DID claim stays unavailable on the new card. Both are correct.

begin;

do $outer$
declare
  v_src text;
  v_avail constant text := 'sc.origin = ''expired''';
  v_core  constant text := 'sc.origin=''expired''';
  v_win   constant text := 'w.origin in (''open'', ''expired'')';
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432';
  if position(v_avail in v_src) = 0 then
    raise exception 'reward_availability_v432 survival arm has moved' using errcode='XX001';
  end if;
  execute replace(v_src, v_avail, 'sc.origin in (''expired'',''claimed'')');

  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'redeem_reward_core';
  if position(v_core in v_src) = 0 then
    raise exception 'redeem_reward_core survival lookup has moved' using errcode='XX001';
  end if;
  execute replace(v_src, v_core, 'sc.origin in (''expired'',''claimed'')');

  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'stamp_reward_expire_due_v464';
  if position(v_win in v_src) = 0 then
    raise exception 'stamp_reward_expire_due_v464 window has moved' using errcode='XX001';
  end if;
  execute replace(v_src, v_win, 'w.origin in (''open'', ''expired'', ''claimed'')');
end $outer$;

-- One claim per GIFT per card is the rule; one claim per SLOT never was.
alter table public.stamp_milestone_claims drop constraint if exists stamp_milestone_claims_slot_uk;

commit;
