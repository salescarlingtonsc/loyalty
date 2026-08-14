# CUX2 — the customer experience, rebuilt around one question

Date: 14 August 2026 · client version tag **v322** · no migration, no RPC, no policy.

Owner directive: *"ensure the customer experience is at the highest level."* The contract for it is
the measured brief `OWNER-SCREENSHOT-2026-08-14-DEFECTS-AND-REDESIGN.md` — nineteen findings taken
in a real Chrome at 390/1440, light and dark, four locales, against the production bundles.

The customer opens this page at a counter with one question: **what can I get right now?** Before
this wave the page answered it after two to three screens of scrolling, twice in duplicate, partly
in the wrong language, with the answer's one action unclickable.

## What shipped

**The page now opens with the answer.** A sticky, opaque wallet strip carries the shop, ONE big
balance and the single most useful action; below it, what is claimable today as tappable rows; then
one line and one thin bar for what is next, with expiry stated; then the tier as a badge; then the
programme cards.

| brief item | what was wrong (measured) | what it does now |
|---|---|---|
| A1 | the stamps card and the points card printed the same `240`/`60` | one pot, one card speaks it; the other speaks its own unit with no number |
| A2 | "Stamp card — 240 **points**" | a stamp card prints stamps or nothing, never the pot's unit |
| A3 | the gift catalogue rendered inside the card headed "Stamp card" | the catalogue lives with the balance it is priced in |
| A4 | content printed under the iOS clock and wifi icon | sticky, opaque strip with `env(safe-area-inset-top)` |
| A5 | nine tier markers on a 324px track, the last 11px off the end | the rail is gone from the phone card (C3) |
| A6 | change tick: 4 skeletons for ~1183ms, 2235→1865px, a 165px scroll throw | hydrated sections are MOVED across the repaint; 0 shells, 0 collapse, 0px throw |
| A7 | 11 reads per idle tick; `actions_v89` twice per load | 1 read per idle tick; `actions_v89` once |
| B1 | "Ready now" was a `role="status"` label | each row is a control that opens that reward's QR in one tap |
| B2 | the SGD 5.00 bring-back credit sat 2.27 screens down | it upgrades the strip's action the moment the growth read lands |
| B3 | no earn rate anywhere | **BLOCKED on a server field** — see the contract below; the client half ships and is proven in four locales |
| B4 | the shop page never mentioned expiry | one quiet line under "next up", from the payload already held |
| B5 | ~9 English strings inside zh-CN/ms/ta cards | 0 — every sentence ct()-routed, 4 locales |
| B6 | tiers and stamps wore a byte-identical glyph | crown / tick / gift / referrals |
| B7 | both accruing cards named the same reward | only the pot-owning card names a target |
| C1–C5 | one 1040px column at 1440; ~2 rewards per screen; 3+ red actions | 2 columns ≥1024; 6 reward rows per screen; exactly 1 solid action |

## Acceptance gates — every row measured in this run

`tests/browser/verify-customer-experience-walkthrough.mjs` (real Chrome, real bundles, 320/390/1440,
light+dark, en/zh-CN/ms/ta): **33 gates, 0 failed, 1 blocked on a server field.**

| gate | before | measured now |
|---|---|---|
| rewards visible per screen @390 | ~2 | **6** |
| primary (solid red) actions on screen @390 | 3+ | **1** |
| duplicate figures across cards | `["240","60"]` ×2 | **none** |
| stamp card unit | "points" | **stamps only** |
| gifts host card | stamps | **points** |
| status-bar collision @390 | yes | **none (opaque sticky strip, inset ≥ safe-area)** |
| tier markers on the phone card | 9 (1 overhanging) | **0** |
| change-tick skeleton flash | 4 shells / ~1183ms / 370px collapse | **0 shells, 0px collapse** |
| scroll jump on refresh while reading | 165px | **0px** |
| RPCs per idle 20s tick | 11 | **1** |
| duplicate RPC per page load | `actions_v89` ×2 | **×1** |
| "Ready now" tappable | no | **one tap to QR** |
| earn rate stated | no | **BLOCKED — server field absent; nothing invented** |
| expiry stated on shop page | no | **"60 points expire on 30 Sept 2026."** |
| non-`ct()` English in zh-CN/ms/ta cards | ~9 strings | **0 / 0 / 0** |
| distinct pictograms per programme | tiers == stamps | **all distinct** |
| 1440 layout | 1 column | **2 columns (514px 514px)** |
| horizontal scroll @320/390/1440 | none | **none** |
| first-visit moment | absent | **fires once, real reward + true distance, honest with no reward, 4 locales** |

## The one gate that needs the server

`earn rate stated` cannot be closed by presentation. Checked against production rather than assumed:
`loyalty_programs.earn_points_per_dollar` / `stamp_per_cents` exist, and **no** customer-facing
reader projects them (`customer_portal_capabilities`, `customer_get_actionable_business`,
`customer_get_business_summary`, `customer_get_business_presentation_v95`,
`customer_get_loyalty_details` — only `staff_get_customer_actionable_loyalty_v145` does, staff-side).

The client half ships switched off: `customerEarnRateLineV322` renders nothing without the field and
renders the honest line the moment it arrives — proven in the walkthrough in en, zh-CN, ms and ta
against the contracted payload. The exact contract is in the build report.

## Verification

- `tests/customer-wallet/v322-customer-experience-redesign.test.mjs` — 22 behavioural pins.
- `tests/business-ui/v322-programme-switches-reach-the-customer.test.mjs` — 5 cross-surface pins:
  the owner's switches and the customer's cards, checked against each other.
- Every existing customer suite green (791 across customer-wallet + customer-modules);
  business-ui 1047 including `v314-programme-switchboard` **11/11**.
- `npm test`: 2990 tests, the single pre-existing environmental failure
  (`store association generator fails closed`, missing Capacitor `PrivacyInfo.xcprivacy`).
- Red-first: 13 node reversals and 6 browser reversals, each producing a NAMED red test or a named
  failing gate, each restored byte-exact by shasum. Recorded in the build report.

## Captures (`docs/qa/evidence/`)

`cux2-shop-390.png`, `cux2-shop-390-dark.png`, `cux2-shop-1440.png`, `cux2-shop-390-tamil.png`,
`cux2-ready-qr-390.png`, `cux2-bring-back-390.png`, `cux2-first-visit-390.png`,
`cux2-nine-tiers-390.png` — first screen, not full page: the first screen is what is under review.

## Regenerated fixture identity

The stylesheet and the `openCustomerPromotionDetailsV104 … customerMerchantExperienceMarkupV95`
source span are inlined under a `production-source-sha256`, so every embedded-source fixture was
regenerated with its own `generate-*.mjs`, and the two that carry captured Chrome measurements were
re-measured in a real browser rather than having their pins edited.

| fixture | production-source-sha256 |
|---|---|
| `tests/browser/reward-overview-owner-visual.html` | `b99215e50120bcef8af54544779ad58a0ea1b1812d3dc97a47c231f2daa6a58d` |
| `tests/browser/v104-promotions-visual.html` | `ab7e44a2033261f686813f189e47e552faca00637db1f21fc351245ad4481bf4` |
| `tests/browser/v129-trial-test-visual.html` | `ac447e39da8b365c0f63c038ac136e4098dc91afc71a1cbd33fb4aa8ef0ee723` |
| `tests/browser/v130-self-serve-visual.html` | `98a6f890cdeefecaa71b9166235b17f5efd067cda9a6387730a8cbfc20b3461a` |
| `tests/browser/v131-store-visual.html` | `6fbdb1acd4a139dd1047caf80a7b94db7a7eecb85f72bb6ab20cddd4712c5f78` |
| `tests/browser/v141-dashboard-visual.html` | `e7ef0315dcd58a6debf56a7806500683968089fa14e4e5f63d6e930e4f87b515` |
| `tests/browser/v142-connect-paynow-visual.html` | `90106fa5326f9ee9b4e02b5c3f9f837cb9f8fce6b743566049adc37a5d558345` |
| `tests/browser/v145-launch-freeze-visual.html` | `e43c06930e298096a523fd521f411dfc98c45c15ebae06ac4edd53e3ee9f9857` |
| `tests/browser/v105-admin-visual.html` | (v105 component sha, regenerated) |

Re-captured through real Chrome: `verify-v104-promotions-visual.mjs` → PASS (1440/390/412 plus
`v104-promotions-production-render-metrics.json`); `verify-v142-connect-paynow.mjs` → PASS.

## Not done, deliberately

- No engine logic, no migration, no RPC, no policy. The four-programme spine, `customer_visible`
  and `businesses.points_mode` are read exactly as before.
- The v194 tab fallback path is untouched — its English, its rail and its markup are byte-identical,
  because it is the CDN-window and rollback path for the v310 gate.
- The growth-offer section keeps its own place and its own control; the strip is a shortcut into it,
  not a second redemption path.
