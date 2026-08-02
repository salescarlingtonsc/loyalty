# V137 minimal automatic rewards setup — acceptance record

Date: 2026-08-02
Issue: `GROW-AUTO-001`
Fixture: `SPA-GLOW` owner Olivia, Facial, active service/product prices, published earning and two stable-ID Signature rewards, Birthday Glow, no draft/existing draft/concurrent draft/read-only variants.

## Owner direction and red reproduction

After asking whether automatic setup was seamless and minimal-click, the owner instructed: **“Please close the gap.”** The source-bound production component reproduced these gaps before implementation:

- new draft: four actions before the detailed editor;
- existing draft: four actions despite zero generator writes;
- lost-response retry: five actions;
- one preselected radio followed by two read-only pseudo-steps;
- the Step-2 continuation below the initial 375×667 viewport and every Step-2 action below the 844×390 viewport;
- an immediate jump into the detailed editor with no concise explanation of what was created;
- **Set up rewards automatically** implied broader coverage than the governed loyalty recommendation actually provides.

## Verified local behavior

Production-component source SHA-256: `1e70e1395b459ec76520cfd2b84655c729ce737197ade97c84d598eb93e64734`.

- A new owner flow is exactly two actions: **Create recommended rewards draft** → **Create draft**. There are no Next/Back pseudo-steps.
- The one review sheet states the governed business type, **Earning rule + one return reward**, the active price input, and that real fulfilment cost is absent. It explicitly says Birthday, Referrals, Memberships and Gift cards are not changed.
- An existing editable draft shows **Continue rewards setup** and opens the Loyalty model editor in one action, without a modal or recommendation RPC.
- Confirmation disables during the request. A lost-response retry uses the same idempotency key. A concurrent server-created draft is resumed rather than duplicated.
- Success remains in a concise handoff showing **Points with milestones**, reference price **SGD 64.00**, reward threshold **320 points**, and **Nothing was published**. A second source-bound `CAFE-HARBOUR` case shows **Stamp card**, reference price **SGD 12.00** and reward threshold **8 stamps**. The governed `classic` fallback shows **Simple points**, reference price **SGD 30.00** and **Set in the draft** when the RPC threshold is null; it never invents **0 points**. The threshold is the RPC's `cost_points` value and is never presented as money. **Review draft** then opens the exact pending Loyalty or Bring-back edit destination.
- Cancel and Escape perform zero writes and return focus to the starting action. Read-only/Retention-only owners receive no generator writer. No setup path calls a publication function.
- Chrome passes desktop 1440×1100, portrait 375×667, mobile 390×844 and 412×915, and landscape 844×390. There is no horizontal overflow, and every visible popup action is at least 44px and remains inside the viewport after the opening animation.
- The literal control inventory intentionally increases by one button for the concise **Back to overview** success handoff; strict wiring/label checks cover 269 buttons and 21 links.
- The final corrected repository-wide gate passes **1,417/1,417** tests. Static build validation passes all six application entry points. The strict inventory maps all 29 business routes and 9 platform routes with zero unlabeled, unwired, invalid, hidden-route or non-semantic controls.

Evidence:

- `tests/business-ui/v137-minimal-auto-rewards.test.mjs`
- `tests/browser/verify-reward-overview-owner.mjs`
- `reward-overview-owner-browser/owner-auto-review-desktop-1440.png`
- `reward-overview-owner-browser/owner-auto-ready-desktop-1440.png`
- `reward-overview-owner-browser/owner-auto-ready-cafe-desktop-1440.png`
- `reward-overview-owner-browser/owner-auto-ready-classic-desktop-1440.png`
- `reward-overview-owner-browser/owner-auto-review-small-375.png`
- `reward-overview-owner-browser/owner-auto-review-landscape-844.png`

This is local source and source-bound browser evidence. No production data, configuration, migration or deployment was changed. Authenticated target owner → staff → customer persistence and independent Sol acceptance remain pending.

## Independent review history

Sol rejected frozen candidate `a00095e97be3529da08232990d5f02e5c77233847bac171afba0bcdb05e0f7dd` with P0=0/P1=1/P2=0 because the first success handoff formatted `suggested_reward_cost` as currency. The V128 RPC stores and returns that field as the `cost_points` threshold: 320 points for `SPA-GLOW` and 8 stamps for `CAFE-HARBOUR`. The corrected candidate adds both source-bound sector cases and rejects the false SGD 3.20/SGD 0.08 representations.

Sol rejected corrected frozen candidate `6dcb9ab5d6d97cfa1513f08e610e2ceff261956d92071415f39ef7a8cb6e0c0f` with P0=0/P1=0/P2=1 because JavaScript `Number(null)` rendered the governed `classic` model's null threshold as **0 points**. The next correction checks the raw field before conversion and adds the source-bound classic outcome above.

Sol independently accepted the final frozen aggregate digest `8332d446c4716e8ed51a4dcac929e6b06891475dfa9c3b516f255a64f15c1573` across 43 files (application SHA-256 `6671aef9822d8cdf33bc228dd29c9eb204f56de2f36489329757c52a4bd5fd8c`, source-bound Grow SHA-256 `1e70e1395b459ec76520cfd2b84655c729ce737197ade97c84d598eb93e64734`) with P0=0, P1=0 and P2=0. The reviewer independently reproduced all three governed handoffs, exact routes, stable retry, responsive actions, focused 22/22 and static build; the frozen digest remained unchanged during review.
