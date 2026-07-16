# 20260716 frenly_v5_memberships_giftcards (applied remotely)
Memberships: membership_plans (price, monthly/annual cadence, credit_cents/period),
memberships (status active/paused/cancel_at_period_end/cancelled, period tracking,
one live membership per client). enroll_membership RPC = membership + sale(kind
membership) + period credit, atomic. app.run_membership_renewals() daily via pg_cron
19:10 UTC: advances periods (catch-up bounded), books charge as sale, drops credit,
honors cancel-at-period-end, skips paused, never double-charges. Manual billing model
(collect in person); Stripe auto-charge = later phase.
Earn trigger updated: sales of kind='membership' earn NO points, don't count as
retention visits, don't qualify referrals.
Gift cards: issue_gift_card RPC (unique GC- code, books retail sale) and
redeem_gift_card RPC (row-locked, partial/full, loads credit_ledger gift_card_load,
auto-status redeemed). Audit triggers cover memberships.
