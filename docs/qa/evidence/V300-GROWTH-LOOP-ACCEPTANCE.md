# V300 — Growth loop: referral sharing, observed come-backs, comparison grains (acceptance evidence)

Owner approval (2026-08-13, this chat): proceed on all three recommendations from the V299
landing-audit — (1) customer referral sharing, synced to the firm's live referral rewards;
(2) came-back counts on the retention surface; (3) calendar comparison grains plus a
choose-your-own baseline on Business Insights, Customer 360 Last visit / Rewards claimed, and
per-reward redemption counts. This approval supersedes the launch feature-freeze for exactly
these scopes and is recorded in PRODUCT-TRUTH.md in this same change.

## Database (applied to production, then mirrored)

`nestly_v300_growth_readbacks` (slot 20260813000100) — three READ-ONLY SECURITY DEFINER
projections; no table created or altered:

- `customer_get_referral_card_v300(p_business_slug)` — wallet-context gated (42501 without a
  verified link); `{enabled:false}` only (no code, no terms) when the programme row or the
  referrals module is off.
- `staff_list_returned_customers_v300(p_business, p_away_days, p_window_days)` — verbatim v244
  valid-visit predicate (reversed visits can never "return"); retention module scope; cap 50
  with an honest truncated flag.
- `business_reward_redemption_counts_v300(p_business)` — per-reward counts over the append-only
  loyalty_redemptions ledger; classic reward-less rows reported separately; loyalty scope.

Rolled-back rehearsal (db/tests/v300_growth_readbacks.sql) passed against PRODUCTION before
apply: live-terms sync, programme-off and module-off `{enabled:false}`, outsider + anon 42501,
reversal-cannot-return, exact away-day gaps (85/62), newest-first ordering, window narrowing,
per-reward counts {2,1}+classic 1, anon ACL floor. Security advisors after apply: 0 ERROR (the
three WARNs are the standard authenticated SECURITY DEFINER advisory every RPC here carries).

## Application

1. **Customer referral card** ([v300-customer-referral-390.png](v300-customer-referral-390.png),
   dark: [v300-customer-referral-dark-390.png](v300-customer-referral-dark-390.png)) — on the
   business programme page under Latest offers: "Give a friend {business}", the firm's LIVE
   terms ("Once they spend SGD 20.00, you get SGD 8.00 in credit"), the member's own code in a
   dashed coupon, Copy + Share (device sheet first; co-branded V264 sheet fallback), and
   "Friends who joined and spent through you: N" (qualified+rewarded only). Renders ONLY from a
   server `{enabled:true}`; every other answer removes the slot. Localised in en/zh-CN/ms/ta.
   Shares are recorded as `customer.referral_shared`.
2. **Come-back card** ([v300-comeback-desktop-1440.png](v300-comeback-desktop-1440.png),
   390px: [v300-comeback-390.png](v300-comeback-390.png)) — on Programmes (tiles view and the
   Lifestyle drill) and on the published retention view: "Gone quiet, and who came back" with a
   30/60/90 threshold segment, AWAY-NOW (v244) and CAME-BACK-IN-30-DAYS (v300) figures that
   share one visit predicate, and a "Returned recently" list (away-days · back-date · Open).
   Copy states "Observed visits only — this card claims no cause"; causal claims stay with the
   playbooks. Missing backend or denied scope removes the card.
3. **Business Insights grains + baseline** — calendar presets (This month / Last month /
   This quarter / Last quarter / This year) fill From/To AND the explicit compare pair with the
   matching previous calendar window (month-to-date vs prior month-to-date, full-vs-full for
   finished units, YTD vs prior YTD; pure string/UTC arithmetic, Asia/Singapore boundaries);
   a collapsed "Compare with different dates" pair overrides the derived baseline for ANY range;
   the verdict band names the explicit baseline ("on the compared period (…)") and keeps the
   exact V297 phrasing for derived windows (V297 walkthrough still PASSES).
4. **Customer 360** — Last visit (same valid-visit set as the page's Visits figure) and Rewards
   claimed (unreversed redemptions, only when the reversal projection loaded).
5. **Reward cards** on Programmes state "Redeemed N times" from the v300 counts; no zero is
   invented and a missing backend leaves cards untouched.

## Regression tests

- `tests/customer-wallet/v300-growth-loop.test.mjs` (6 tests) — fails before, passes after.
- Full gate: `npm run validate` green except the pre-existing environment-bound
  `tests/mobile/v131-store-publication-readiness.test.mjs` sub-test (needs real Apple/Android
  signing env; fails identically on pristine main on this machine; untouched by V300).
- V296 programmes and V297 insights walkthroughs PASS against the V300 bundles.

## Regenerated fixture identity

reward-overview-owner-visual.html production-source-sha256:

    f326609c3bc26e8e5214072a719fa6ccf33847ba2f230439d290b74a979c9220

Captures were produced through the stamped production bundles with the in-page Supabase stub
(v296 seam) — 27 customer captures (light/dark × 390/1440) and the Programmes captures above,
zero page errors.

This row is `VERIFIED_BROWSER` at capture time (database layer `VERIFIED_DATABASE` via the
production rolled-back rehearsal); production verification follows the deploy.
