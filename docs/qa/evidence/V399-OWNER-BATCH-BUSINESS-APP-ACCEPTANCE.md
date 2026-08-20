# V399 owner annotation batch — business app acceptance

Date: 2026-08-20
Branch: `claude/v399-business-batch`
Input: nine annotated screenshots of `peekaa.asia`, build `8f2584143e7d` (commit
`8f25841`, nestly_v396). The annotations are the requirements.

Regenerated production-component fixtures: the V104 promotions, V105 admin,
V129, V130, V131, V141, V142, V145 and V181 fixtures embed the shared inline
stylesheet from `app/index.html`, so this batch moves their source hashes; each
was mechanically regenerated and the V104 and V142 Chromium metrics recaptured.
`reward-overview-owner-visual.html` is deliberately NOT regenerated here: it is
stale on `origin/main` by many versions (v337 through v386) of another work
stream's app.js edits, and regenerating it would pull ~1800 lines of unrelated
drift into this batch. It is left for its own stream to refresh.

## What was measured, not read

Three of the marked items turned out to be CSS specificity or layout defects
whose shipped rule never reached the screen. Each was measured in Chromium
(playwright-core against the real stylesheet) before and after, because reading
the stylesheet would have confirmed a rule that the cascade was discarding.

1. **Record sale number (photo 1, "increase size, too small").**
   `.frontline-phone` is (0,1,0); the base control rule
   `input:not([type="checkbox"]):not([type="radio"])` is (0,2,1) and wins, so the
   declared 34px had never applied and the number rendered at the ordinary 15px
   control size. Measured `font-size: 15px` on the shipped rule. The selector now
   carries the card — `.frontline-card input.frontline-phone`, (0,2,1) and later
   in the sheet — and the size is 46px. Measured 46px at 1440 / 768 / 390, card
   at its 460px max, no text overflow, no page scroll.

2. **Dashboard KPI row (photo 6, "fill until here too empty").**
   `repeat(auto-fit,minmax(170px,1fr))` cannot collapse a track that something
   occupies, and the delta legend inside `#kpis` is a `grid-column:1/-1` item, so
   it held every track open. Measured at 1440px: five tracks for four tiles, the
   row ending 211px short of the card. Removing the legend in-page took the gap
   to 0, isolating the cause. The grid now follows `--kpi-count`, published by
   the painter from the tiles that actually rendered. Measured right-edge gap 0
   at 2, 3 and 4 tiles at 1440px; the <=1100px two-column rule is unchanged.

3. **Rewards banner on Record sale (photo 3).**
   `.permission-banner` is `display:flex` with the default row direction, so the
   heading, the instruction, every reward row and the scan button were flex items
   on ONE line — visible in the owner's own photo. V372 fixed exactly this for
   the sibling tier banner with `.till-tier-benefits-v369`; the V392 gifts banner
   never received the class. Measured before: three reward rows all at `top:73`.
   After: 334 / 422 / 495. V372's `align-items:stretch` was itself being beaten
   by `.permission-banner{align-items:flex-start}` at equal specificity and later
   in the sheet, so rows measured 59-84px wide instead of filling; qualifying the
   rule to `.permission-banner.till-tier-benefits-v369` takes it to (0,2,0) and
   rows measure 482px. The status pill, a `<span>` where the tier rows end in a
   `<button>`, was inheriting `flex:1` and is now sized by its word (55px).

## Copy and structure changes

- Till tab `Benefits` -> `Rewards` (photos 2 and 3). State key stays `benefits`.
- `What they had last` caption removed (photo 2). The history-first ordering of
  the grid is unchanged; only the label is gone.
- `Scan customer QR` in the rewards banner is the compact 44px icon control
  (photo 3), same id and handler, full accessible name retained.
- Programme usage: quick-range shortcuts moved onto the From/To/Apply/Clear row
  (photo 4, "Quick button here"); the `Compare with` segment and the
  `Period before` column are removed ("don't need compare"), together with the
  second per-render `business_programme_usage_v386` round trip that fed them.
  The chart falls back to its single-series form.
- Customers: an `All` card leads the summary chips (photo 7), showing
  `counts.total` from the same `staff_customer_bucket_counts_v290` read that
  produces the three bucket counts, and clearing the filter.
- Tier membership (photo 8): `Change` -> `Edit`; the programme on/off switch
  moved from the Manage-tiers header onto the basis card with a green On / grey
  Off state pill; ladder stops carry the tier's own glyph, the same
  threshold-derived icon the tier rows use.

## Responsive

1440 / 768 / 390 checked on every changed surface. No horizontal page scroll at
any width; customer chips stack; the tier basis card goes to its column layout.

## Evidence limits

This is local production-component browser evidence against the real stylesheet
and the real markup, plus the repository's own suite. It is not a signed-in
production tenant record. Two annotations were NOT implemented and are reported
separately: the manual-redeem button (photo 3), which needs a server RPC that
v94 deliberately revoked from the browser, and the schedule/Performance date
link (photo 6), whose handlers were traced intact and whose reported failure
could not be reproduced without a live session.

Suite: `npm run validate` — 3185/3185 tests, quality, bundle-stamp, runtime
config, migration manifest, canonical migrations and static build all pass.
