# Grow Program Recommender

Frenly's Grow tab helps a firm pick numbers for its own points program,
membership, and gift cards — points-per-dollar, redemption thresholds, reward
credit, membership pricing, gift card denominations — without needing to do
the arithmetic themselves or guess what's safe.

## Owner rulings this is built on

- **Firms set their own figures. Frenly never sets pricing on their behalf.**
  Same ruling as staff commission (2026-07-18): the platform provides the
  mechanism and a sane starting point; the number that actually goes live is
  the firm's decision, made in their own settings screen.
- **Recommend-only, not enforced.** The recommender pre-fills a suggestion and
  shows the math behind it. A firm can override every field. Nothing here
  blocks a save.
- **No fake AI.** These are pure, deterministic formulas — the same inputs
  always produce the same outputs. There is no model, no "personalization,"
  no hidden randomness. Every number on screen can be reproduced by hand from
  the formulas below.
- **Retention lift numbers are ranges with a disclaimer, not a promise.** They
  come from industry-pattern estimates, not from this firm's own data, and
  the UI must say so every time a range is shown.

## The giveback formula, and the kopi tiam incident

"Giveback %" is the percentage of every dollar a customer spends that the
business ends up handing back as reward credit. It is the single most
important number in the whole Grow tab, because get it wrong and the loyalty
program bleeds money quietly, sale after sale, until someone notices the
liability.

```
giveback% = earnPointsPerDollar × rewardCreditCents / redeemPoints
```

The cautionary example we test against by name is the **kopi tiam incident**:
a coffee shop configuration of 100 points earned per dollar, redeemable for a
$3.00 (300-cent) reward at only 150 points.

```
giveback% = 100 × 300 / 150 = 200%
```

That business would give back **$2 of credit for every $1 a customer spent** —
double their revenue, on every redemption, forever. That is the exact
misconfiguration the recommender exists to prevent by defaulting firms into
sane numbers and showing the giveback percentage plainly before they save
anything unusual.

## The non-blocking-meter rule

The giveback meter is a **warning light, not a lock.** A firm is free to set
a 200% giveback program if that is genuinely what they want — Frenly is not
their accountant and does not get to override a business decision. What the
meter guarantees is that they cannot do it *by accident*: the percentage is
always computed and always visible next to the fields that produce it, in
plain language, before save.

## Formula contract (pinned, verbatim)

`window.FrenlyGrowRec` / `module.exports`, pure and deterministic. All money
values are integer cents. `roundToNearest(x, n) = Math.round(x / n) * n`.
Every function is null-safe: invalid input (null, NaN, negative, missing
fields, wrong type) never throws — it returns a null-shaped result instead.

1. **`givebackPct({earnPointsPerDollar, redeemPoints, rewardCreditCents})`**
   → percent, rounded to 2 decimals.
   `earn × credit / redeem`. `null` if `redeemPoints <= 0` or any input is not
   a finite number `>= 0`.
   Examples: `(1, 150, 300) → 2`; `(100, 150, 300) → 200` (kopi tiam);
   `(10, 600, 300) → 5`.

2. **`recommendPoints({avgTicketCents, targetGivebackPct})`** →
   `{earnPointsPerDollar, redeemPoints, rewardCreditCents, actualGivebackPct,
   costPerVisitCents, costPer100VisitsCents, reasoning[]}`
   - `earnPointsPerDollar` is always `10`.
   - `rewardCreditCents = clamp(roundToNearest(avgTicketCents / 2, 100), 200, 2000)`
   - `redeemPoints = max(roundToNearest(10 × rewardCreditCents / targetGivebackPct, 50), 50)`
   - `actualGivebackPct` is **recomputed** from the rounded outputs via
     formula 1 — it is not a passthrough of `targetGivebackPct`. Rounding the
     credit and the redeem threshold to clean numbers means the actual
     giveback a firm ends up with can drift a little from what they typed in;
     the UI must show the real number, not the aspiration.
   - `costPerVisitCents = round(avgTicketCents × actualGivebackPct / 100)`
   - `costPer100VisitsCents = costPerVisitCents × 100`
   - `reasoning` is a non-empty array of plain-language strings explaining the
     numbers above.

3. **`recommendMembership({avgTicketCents})`** →
   `{monthlyPriceCents, breakevenVisits, reasoning[]}`
   - `monthlyPriceCents = max(roundToNearest(avgTicketCents × 2.5, 500), 1000)`
   - `breakevenVisits = +(monthlyPriceCents / avgTicketCents).toFixed(1)`

4. **`recommendGiftCards({avgTicketCents})`** →
   `{denominationsCents, reasoning[]}`
   - Three tiers — 1×, 2×, 4× `avgTicketCents` — each independently run
     through `max(roundToNearest(·, 500), 500)`, then deduplicated and sorted
     ascending. A low-ticket business can see all three tiers collapse to a
     single $5 denomination; that's expected, not a bug.

5. **`estimateRetentionLift(type)`** → `{lowPct, highPct, disclaimer}`, where
   `disclaimer` always contains the word "estimate":
   - `points`: 5–15%
   - `membership`: 10–25%
   - `giftcard`: 2–8%
   - `bringback`: 5–20%

6. **`catalogMetrics(items)`** → `{avgTicketCents, sampleItems, count}`, from
   an array of `{name, price_cents}`.
   - `avgTicketCents` is the **median** price, as an integer. Odd count takes
     the middle value; even count takes the rounded mean of the middle two
     (e.g. `[400, 600] → 500`).
   - `sampleItems` is the top 3 items by price descending, `{name, price_cents}`.
   - Empty or invalid input → `{avgTicketCents: null, sampleItems: [], count: 0}`.

## Surfaces

- **Loyalty meter + recommend card** (Growth → Loyalty): the giveback % meter
  next to the earn-rate / redeem-threshold / reward-credit fields, backed by
  `givebackPct` and `recommendPoints`. This is the primary surface — the one
  that exists because of the kopi tiam incident.
- **Memberships hint** (Growth → Memberships): a suggested monthly price and
  breakeven-visits note next to the plan price field, backed by
  `recommendMembership`.
- **Gift cards hint** (Growth → Gift Cards): suggested denominations next to
  the gift card setup form, backed by `recommendGiftCards`.
- Both the memberships and gift cards hints, and any "expected retention
  lift" copy shown alongside them, are pre-filled suggestions the firm can
  freely override — never a required value, per the non-blocking-meter rule.

## Estimate disclaimers

Anywhere `estimateRetentionLift` output reaches the UI, the disclaimer text
must be shown alongside the percentage range, not just carried in the data —
a lift range without its disclaimer reads as a guarantee, which it is not.
The same spirit applies to `reasoning[]` on the three recommend functions:
it exists to show the firm the arithmetic, not to talk them into a number.

## Orchestrator ruling — null-shape for invalid inputs (closes the flagged ambiguity, 2026-07-25)
For `recommendPoints` / `recommendMembership` / `recommendGiftCards`: invalid input returns the FULL
object shape with `null` numeric fields and `[]` arrays (the `catalogMetrics` precedent), never a bare
`null` and never a thrown error. `givebackPct` alone returns bare `null`. `avgTicketCents <= 0` is
invalid (zero would divide to Infinity in breakeven maths). This is the canonical contract shape as
implemented and test-verified (34/34); future changes must keep it.

## Known scope limits (flagged by the implementer, accepted)
- Meter + recommender render for the `classic` loyalty model only: `stamps` has no points;
  `points_tiers` prices rewards per-row, so a single meter/apply pair does not exist. Extending to
  `points_tiers` = follow-up work, not silent scope creep.
- Reasoning strings inside the pure module use `$` notation; figure tiles use the house `money()`
  (e.g. `SGD 12.00`). Cosmetic; module stays currency-agnostic by design.
