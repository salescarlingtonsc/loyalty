-- nestly_v377 — no reward type pays store credit.
--
-- The last way to create store credit from the workspace. public.firm_reward_taxonomy holds the
-- labels a bring-back reward is built from, and each label carries an IMMUTABLE fulfilment
-- behaviour; eleven businesses each had an active 'credit' label, so a retention reward could
-- still have been configured to mint credit long after v375 retired the classic model and v376
-- withdrew the customer-facing offer. app/app.js stops offering "Add store credit" when a new
-- label is created; this retires the ones that already exist.
--
-- RETIRED, not deleted, and not rewritten. The surface's own contract is "Labels may be renamed,
-- sorted, or retired. Their financial behavior can never be changed", so `active=false` is the
-- sanctioned instrument and `active=true` reverses it exactly. No row is removed, no
-- fulfillment_kind is altered, and any historical reward that was built on one of these labels
-- keeps its record intact.
--
-- Safe because nothing live is built on one: production has a single active retention programme
-- and it pays a percentage discount. Verified in the acceptance suite as check 02, so the
-- migration cannot silently strip the reward type from a running programme.
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-17 — see
-- db/tests/v377_no_credit_reward_types.sql. Five checks: 11 active credit labels before; no live
-- programme depends on one; none selectable after; free_item and discount_pct untouched; and the
-- rows are still on file.

begin;

update public.firm_reward_taxonomy
   set active = false
 where fulfillment_kind = 'credit'
   and active;

commit;
