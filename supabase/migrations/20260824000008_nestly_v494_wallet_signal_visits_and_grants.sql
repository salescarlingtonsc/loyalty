-- nestly_v494 — a visit and a granted reward ring the customer's doorbell too
-- (owner, 2026-08-24: "stamps issued to customer is now immediately seen on customer app, but for
--  points and tier — ensure the rewards and points / visits are also immediately reflected. same
--  design."; Sol review bypassed on the owner's explicit instruction)
--
-- WHAT WAS ALREADY TRUE. v479's signal fires from a trigger on public.points_ledger, and STAMPS
-- ARE points_ledger rows — a stamps programme's balance is that ledger filtered by programme_id.
-- So points were never the slow half: any sale that EARNS already pings, in stamps and points
-- alike. Nothing about the mechanism needed changing, which is why this migration adds no new
-- function and no new table.
--
-- WHAT WAS NOT. Three things a customer sees change without a single ledger row being appended,
-- and each of them was left to the 20-second poll:
--   * A VISIT. sales.counts_as_visit is what tier ladders on a 'visits' basis count, and a $0
--     visit — a used package session, a completed appointment with nothing to pay, a redemption
--     -generated sale — appends nothing to points_ledger. The owner named this one outright.
--   * A GRANTED REWARD. welcome_offer_grants_v215, bringback_grants_v361, referral_grants_v420
--     and reward_grants are issued server-side, and the gift lands in the customer's wallet with
--     no ledger append behind it.
--   * A REDEMPTION settled at the counter. loyalty_redemptions and stamp_milestone_claims are
--     what make a gift stop being claimable; until the poll came round the customer's phone still
--     offered a reward the counter had just taken.
--
-- THE SHAPE IS DELIBERATELY THE SAME. app.bump_customer_wallet_signal_v479 reads only
-- new.business_id and new.client_id, so it attaches to all seven tables unchanged — same
-- doorbell, same row, same swallow-everything exception handler, and therefore the same
-- guarantee: a signal can never break the write it rides on. No figure travels in the ping; the
-- watcher still re-reads the ledger for every number it prints, so nothing here can put a
-- balance on screen that the server would not confirm.
--
-- The client needs no change at all: the watcher already subscribes to
-- customer_wallet_signals_v479 and the poll stays as the fallback for a dropped socket.

begin;

-- A visit, whether or not it earned anything.
drop trigger if exists trg_sales_signal_v494 on public.sales;
create trigger trg_sales_signal_v494
  after insert on public.sales
  for each row execute function app.bump_customer_wallet_signal_v479();

-- A gift arriving.
drop trigger if exists trg_welcome_grant_signal_v494 on public.welcome_offer_grants_v215;
create trigger trg_welcome_grant_signal_v494
  after insert on public.welcome_offer_grants_v215
  for each row execute function app.bump_customer_wallet_signal_v479();

drop trigger if exists trg_bringback_grant_signal_v494 on public.bringback_grants_v361;
create trigger trg_bringback_grant_signal_v494
  after insert on public.bringback_grants_v361
  for each row execute function app.bump_customer_wallet_signal_v479();

drop trigger if exists trg_referral_grant_signal_v494 on public.referral_grants_v420;
create trigger trg_referral_grant_signal_v494
  after insert on public.referral_grants_v420
  for each row execute function app.bump_customer_wallet_signal_v479();

drop trigger if exists trg_reward_grant_signal_v494 on public.reward_grants;
create trigger trg_reward_grant_signal_v494
  after insert on public.reward_grants
  for each row execute function app.bump_customer_wallet_signal_v479();

-- A gift leaving, because the counter just honoured it.
drop trigger if exists trg_redemption_signal_v494 on public.loyalty_redemptions;
create trigger trg_redemption_signal_v494
  after insert on public.loyalty_redemptions
  for each row execute function app.bump_customer_wallet_signal_v479();

drop trigger if exists trg_milestone_claim_signal_v494 on public.stamp_milestone_claims;
create trigger trg_milestone_claim_signal_v494
  after insert on public.stamp_milestone_claims
  for each row execute function app.bump_customer_wallet_signal_v479();

commit;
