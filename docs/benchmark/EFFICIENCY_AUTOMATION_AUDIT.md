# EFFICIENCY_AUTOMATION_AUDIT

The real value of the benchmark is its **automations** — what it removed from human
hands. Each entry: manual-before → automated-now → exact benefit → how Avocado reproduces
and improves it.

### A1 · Automatic loyalty earning on completion/Quick Sale
- **Before:** staff manually stamp a punch card or key points at the desk; missed stamps, disputes, queues.
- **Now:** marking an appointment complete, or closing a Quick Sale, earns points/stamp automatically; balance updates live.
- **Benefit:** removes a per-transaction manual step (seconds × every visit), eliminates missed/disputed earns, no nightly batch. Front desk operates nothing.
- **Reproduce:** single `visit.completed` / `sale.closed` event → `points_ledger` insert (idempotent per visit).
- **Improve:** earn on **full basket** (service + add-on retail, net of discount) — Flowesce self-discloses this as a gap; ship it day one. Configurable per-product/category/outlet multipliers.

### A2 · Redeem-to-credit in one move
- **Before:** manual voucher issue + tracking a separate reward balance.
- **Now:** redeeming a tier mints in-store credit into the **same ledger** the POS reads; spendable immediately.
- **Benefit:** no separate voucher system to reconcile; reward is money-on-account, one balance.
- **Reproduce:** redeem = burn points + insert `credit_ledger(loyalty_redeem)` in one transaction.
- **Improve:** allow catalogue rewards (free service, retail item, partner reward) in addition to credit.

### A3 · Daily points-expiry sweep
- **Before:** spreadsheet tracking of who's expiring; manual zeroing; inflated liability.
- **Now:** a daily job expires point batches per mode (none / inactivity-reset / fixed-from-earn, oldest-first); displayed balance is always real.
- **Benefit:** loyalty **liability stays accurate** without accounting effort; enables honest financial reporting.
- **Reproduce:** scheduled job → negative expiry entries against oldest live batch; never mutate balances.
- **Improve:** fire an **expiry-reminder campaign** N days before a batch burns (win-back lever Flowesce lacks); surface live liability on dashboard.

### A4 · Referral attribution + reward-on-completion
- **Before:** honor-system word of mouth; nothing tracked; manual thank-you rewards.
- **Now:** personal code per client, attributed at booking, reward auto-issued only after referred client's **first qualifying completed visit** (min-spend enforced).
- **Benefit:** removes manual attribution + issuance; **self-funding** (pays only after real revenue); fraud-resistant (no payout on no-show).
- **Reproduce:** `referrals` with code + `attributed_at`; on referred `visit.completed` & min-spend, issue one credit reward (idempotent).
- **Improve:** multi-tier ("refer 3 → bonus"), ambassador/influencer codes, corporate referrals, abuse detection (same-device/self-referral).

### A5 · Membership renewals (daily job) + credits refresh
- **Before:** manual monthly re-billing + manually granting monthly credits; missed renewals = lost revenue.
- **Now:** daily job renews at period boundary in tenant tz, refreshes credit pool, books a `sale`; honors pause & cancel-at-period-end; never double-charges.
- **Benefit:** recurring revenue collected without human tracking; credits land on time; revenue flows to P&L automatically.
- **Reproduce:** renewal job over `memberships` due today; idempotent per period.
- **Improve:** proration, plan change mid-cycle, annual+monthly hybrid, gifting a membership.

### A6 · Membership auto-charge + dunning (Singapore)
- **Before:** chase failed card payments by hand; awkward cancellations.
- **Now:** Stripe off-session charge; failed charge retries across a grace window; clean lapse + email to owner and client.
- **Benefit:** recovers failed payments automatically; no silent lapses; no card handling by staff.
- **Reproduce:** Stripe subscriptions/off-session PI + webhook-driven dunning state machine.
- **Improve:** PayNow/GrabPay recovery options; in-app "update card" deep link in the dunning email.

### A7 · Membership charge = a Sale (unified revenue)
- **Before:** membership income tracked in a side tool, disconnected from P&L.
- **Now:** every charge writes a `sale(kind=membership)` → shows in revenue/P&L beside services and retail.
- **Benefit:** one revenue truth; recurring-revenue contribution visible without spreadsheet merging.
- **Reproduce:** all money events write to one `sales` table with `kind`.

### A8 · One credit ledger for refunds, gift cards, loyalty, referrals, memberships
- **Before:** separate balances/vouchers to reconcile.
- **Now:** all mint/spend through one in-store-credit ledger; credit is a tender at checkout.
- **Benefit:** single reconciliation surface; accurate liability; no orphan balances.
- **Reproduce:** central `credit_ledger` (append-only) + `client_credit_balance` view (already built ✔).

### A9 · Consent-gated comms
- **Before:** risk of messaging without consent (PDPA exposure).
- **Now:** sends check consent + preferences first.
- **Benefit:** compliance safety + fewer complaints.
- **Reproduce:** `consents` (append-only) checked before every send.
- **Improve:** per-channel consent (email/SMS/WhatsApp), one-tap unsubscribe, audit trail.

### A10 · CSV import migration
- **Before:** manual re-keying when switching software.
- **Now:** CSV import from Mangomint/Fresha/Acuity.
- **Benefit:** removes migration friction (a top switching blocker).
- **Improve:** map-and-preview importer + points/credit-balance import + dedupe.

## Top efficiencies to reproduce first (ranked)
1. A1 earn-on-completion · 2. A3 expiry sweep · 3. A2 redeem-to-credit · 4. A4 referral payout · 5. A8 unified ledger. These five *are* the loyalty product.
