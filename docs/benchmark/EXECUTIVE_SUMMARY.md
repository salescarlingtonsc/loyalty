# EXECUTIVE_SUMMARY — Flowesce benchmark → Avocado

## The one-paragraph version
Flowesce is a **salon operating system** in which **loyalty is a single Growth-tier
module**, not a standalone product. Its loyalty engine is genuinely good and worth
reproducing: **real spendable in-store credit** (not vanity points) minted through **one
append-only credit ledger** that also powers referrals, gift cards, memberships and
refunds; loyalty that **earns automatically** on completed visits and Quick Sales; **three
honest points-expiry modes with a daily sweep**; and **self-funding referrals** that only
pay after a referred client's first qualifying visit. Its weaknesses are exactly Avocado's
opening: it's salon-locked, **email-only** (no WhatsApp/SMS — fatal in Singapore), has **no
tiers, no gamification, no wallet passes, no loyalty analytics, no AI, and no open API**.
Avocado should extract the engine and automations, generalize them to any business type,
and win on the channels and intelligence Flowesce ignores.

## What Flowesce does well (reproduce)
Real-credit rewards on a unified ledger; auto-earn on completion/Quick Sale; daily expiry
sweep keeping liability honest; self-funding referral payout on qualified completion;
membership renewals + Singapore Stripe auto-charge with dunning; every money event booked
as a sale into one P&L; unusually honest, plain-English UX.

## What it does poorly (Avocado's opening)
Loyalty trapped in a salon OS; earns on headline service price only (misses add-ons and
discounts); credit-only single-tier rewards (no VIP status); single-tier email-only
referrals; **email-only comms**; no gamification; no wallet/QR; no loyalty analytics
(breakage, liability, CLV, RFM, cohort); no AI; no coalition; no open API/webhooks;
online payments Singapore-only.

## Strongest efficiencies to reproduce first
1. Auto-earn on completion/Quick Sale · 2. Daily points-expiry sweep · 3. One-move
redeem-to-credit · 4. Referral attribution + reward-on-qualified-completion · 5. The single
unified credit ledger. (Detail in `EFFICIENCY_AUTOMATION_AUDIT.md`.)

## Avocado reuse
- **Reuse now:** multi-tenant schema with RLS on every table; the append-only
  `credit_ledger` + balance view (already matches Flowesce's spine); core entities.
- **Refactor/extend:** `clients` (+consent/prefs), `referrals` (+qualifiers), a real
  `sales` table.
- **Critical missing (build):** `points_ledger` + expiry batches, memberships, consent,
  audit log, WhatsApp/SMS, jobs runner. (No booking/calendar/inventory — out of scope.)

## Recommended Singapore MVP
Real-credit loyalty end-to-end (earn on full basket → redeem to credit → 3-mode expiry),
member 360, PDPA consent, low-friction onboarding — then referrals, memberships, and
**WhatsApp/SMS** for parity.

## Best initial segment & GTM
**F&B multi-outlet cafés** (visit frequency compounds loyalty; QR-at-table + WhatsApp fit),
expanding to beauty and fitness on the same engine. Flat + per-outlet pricing, **no
per-member fee**; free no-card trial with one-click export; POS-partner + agency
distribution; migration offer as the switching lever. (All pricing ⚠️ needs your confirm.)

## Top 10 implementation priorities
1. `sales`(kind) + `points_ledger` + `points_batches` schema · 2. EarnService (idempotent,
full basket) · 3. Credit ledger + redeem · 4. Daily expiry job · 5. Member 360 + audited
manual adjust · 6. PDPA consent · 7. Referrals w/ qualifiers · 8. Memberships + renewal +
SG dunning · 9. WhatsApp/SMS + birthday/win-back · 10. Loyalty analytics (breakage + live
liability).

## Top 10 commercial opportunities
1. WhatsApp-native loyalty (SG) · 2. Real-credit rewards trust play · 3. Tiers/VIP status ·
4. Gamification tied to real rewards · 5. Wallet passes + QR identity · 6. AI loyalty
copilot (churn/next-best-action/expiry campaigns) · 7. Self-funding multi-tier referrals ·
8. POS-agnostic + open API/embed · 9. Agency/reseller program · 10. Coalition/cross-merchant
(later).

## Top 10 risks
1. Ledger/points-calc correctness (financial) · 2. Double earn/redeem under concurrency ·
3. Loyalty-liability accuracy · 4. PDPA/consent ⚖️ · 5. WhatsApp/SMS sender onboarding ⚖️ ·
6. Multi-tenant isolation leaks · 7. Scope creep into a full salon OS · 8. Migration data
integrity · 9. Idempotency on transaction ingestion · 10. Building international complexity
before SG PMF.

## Realistic path to SG leadership
Win F&B cafés with a WhatsApp-native, real-credit loyalty product that's live in an
afternoon and migrates their old stamp app in one click; prove ROI with live liability +
breakage analytics; expand to beauty/fitness on the same engine; add tiers, gamification,
wallet, and an AI copilot as the moat; open a POS-partner + agency channel; only then look
overseas.

## Postpone until overseas
Multi-country tax/data-residency, non-SG payment corridors, coalition at scale, native
mobile apps, reward marketplace.

> Evidence + caveats in `REVIEW_LOG.md`; unresolved items in `OPEN_QUESTIONS.md`. Loyalty
> config screens were **not** opened (paywalled — would require a billing change).
