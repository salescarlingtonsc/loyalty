# V299 — Customer-experience and Insights presentation polish (acceptance evidence)

Owner request (2026-08-13): audit the landing page's promises against the shipped product,
review the customer app "as the customer", and make it maximally friendly and beautiful —
**without changing logic, using existing code**. This increment is presentation-only: no RPC,
no migration, no earning/redemption/booking semantics touched.

## What changed (all presentation)

Customer surface:
1. Offer artwork fallbacks show a small business-monogram coin over a soft wash instead of a
   giant first letter of the offer name ("2-for-1 lattes" used to render a huge lone "2") —
   Home shelf, programme promotion card, and offer-detail sheet.
2. Tiers+points ("both") mode: the spendable balance now reads on the Tier/Reward-points tab
   bar itself (`.customer-programme-tab-balance`); it was previously invisible until the
   customer tapped the unselected tab. Hidden while the programme is paused so it can never
   contradict the "Programme paused" sentence.
3. `.wallet-reward` (the claim surface) sheds its legacy 7px corner radius for the sibling-card
   14px and gains breathing room.
4. Customer-surface footers pass the member's locale to `legalLinks()` (zh-CN / ms members no
   longer get an English-only legal footer; ta falls back to English as before).
5. Wallet section headings that bypassed the `walletSectionShell` ct() chokepoint are now
   translated (Packages, Membership, Recent activity, Full history, Rate your visit, and the
   Transactions & points empty state), with dictionary rows added in en / zh-CN / ms / ta.

Business surfaces:
6. `.metric` and `.report-scope-card` finally have CSS — every Business Insights tab's headline
   number used to render at body size under the 1.85rem V297 verdict value.
7. Business Insights quick ranges (7/30/90 days, 6/12 months) fill the SAME From/To pair and
   press the same Run — no new computation path; comparison stays the derived previous
   equal-length window.
8. Dashboard delta chip gains the red "down" tone (was the identical grey pill for −18% and 0%).
9. The V297 Efficiency and Retention cards no longer restate the previous-period figure their
   own verdict band states one line above.
10. Report share-bar palette moved onto `:root` `--chart-1..6` tokens; the bring-back playbook
    reuses the shared `report-share-bar-v297` bar and its headline is ink, not disabled grey.
11. Dashboard KPI grid is tile-count-agnostic (`auto-fit`), so 2- and 3-tile role permutations
    no longer float in a fixed 4-column row.
12. Customer 360 states **Member since** from the already-fetched client row (`created_at`
    added to the existing select; no new call). Absent stays absent — no "Unavailable" filler.

## Regression tests (fail before, pass after)

- `tests/customer-wallet/v299-customer-experience-polish.test.mjs` (7 tests)
- `tests/business-ui/v299-insights-dashboard-polish.test.mjs` (7 tests)

Adjusted stale source pins whose rendered intent is unchanged (all verified line-by-line):
`v167-booking-history-mobile` (ct-wrapped headings), `v169-reward-promo-clarity` (business
monogram derivation), `c45-birthday-benefits` (clients select allowlist + `created_at`; still
no DOB anywhere).

## Generator drift fixed in passing

`tests/browser/generate-reward-overview-owner-visual.mjs` extracted a `growPage` that now calls
`promotionEditorItemV104` (V295 promotions drilling) and the V291 pending-changes helpers —
the regenerated fixture threw `ReferenceError` before `#rewardJourneyTitle` rendered. Both
helper regions are now extracted and injected. Regenerated fixture production-source-sha256:

    f8c996c2d1ed0a8b05ab36b286fbd3a420352ee68b6eec0b493a2774eaff6df6

## Browser evidence (real bundles, real router, in-page Supabase fixture; 390px + 1440px)

Captured through the stamped production chunks with a three-business customer fixture
(facial studio with tiers+points+package+appointment, café with stamps, fitness with credit),
modeled on the canonical REALISTIC-FIXTURES personas:

- `v299-before-customer-home-390.png` / `v299-customer-home-390.png`
- `v299-before-customer-merchant-390.png` / `v299-customer-merchant-390.png`
  (before: balance invisible on the default Tier tab, giant "N" offer fallback;
   after: `300 points` on the tab bar, monogram coin)
- `v299-customer-merchant-open-390.png` (tier ladder + transactions trace open)
- `v299-customer-programmes-390.png`, `v299-customer-offer-sheet-390.png`
- `v299-customer-home-dark-390.png`, `v299-customer-merchant-dark-390.png` (customer dark theme)
- `v299-customer-merchant-desktop-1440.png`

Zero page errors across all 27 captures (light/dark × 390/1440 × 9 screens).

## Verification levels

- `npm run bundle-stamp` re-split and re-stamped chunks (core/auth/customer/business/i18n).
- `npm run validate`: full suite green except `tests/mobile/v131-store-publication-readiness.test.mjs`
  (1 sub-test), which requires the real `APPLE_TEAM_ID` / `ANDROID_SHA256_CERT_FINGERPRINT`
  environment and the Capacitor privacy manifests in `node_modules` — proven **pre-existing**
  by failing identically on a pristine `origin/main` (d4c7b8b) copy on this machine. No mobile
  file is touched by V299.
- V296 programmes walkthrough and V297 insights walkthrough (real-bundle, stubbed-client) both
  PASS against the V299 bundles.
- Evidence recaptured for v104 promotions and v142 connect/paynow against the new component
  bytes (their verify scripts, PASS).

This row is `VERIFIED_BROWSER` at capture time; production verification follows the deploy.
