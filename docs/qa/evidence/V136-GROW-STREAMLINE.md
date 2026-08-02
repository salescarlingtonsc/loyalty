# V136 Grow streamline — acceptance record

Date: 2026-08-02
Issue: `GROW-002`
Fixture: `SPA-GLOW` owner, published points programme, two duplicate-name active rewards with distinct UUIDs, one birthday benefit, one archived reward, editable draft present.

## Owner complaint preserved

> “relook into the grow modules - the page is too flooded with information and left right bottom are so much information. It needs to be streamline and easy to create or edit. They must be able to use the module even without anyone teaching them. The overview should include all the rewards program & program yet to set up. Ensure that clicking in will bring them directly to the specific page and specific edits”

## Red-state reproduction

The checked-in production-component browser fixture was regenerated from `app/index.html` before implementation and opened in headless Google Chrome.

- Desktop 1440×900: the overview rendered as two equal columns (`562px 562px`) and exposed six competing first-viewport controls: automatic setup, Add reward, earning, two same-name rewards and birthday/archived entries. The Grow body carried 2,521 characters of instructional content, including 1,427 characters inside the secondary section.
- Mobile 390×844: the page was 1,200px tall before opening any editor or secondary disclosure. Only the first three reward entries fit in the viewport; birthday and the other programme types were below the fold.
- Both sizes avoided horizontal overflow, but the overview had no rows for bring-back, referrals, memberships or gift cards. Owners therefore could not tell from the overview whether those programmes were configured, available to set up, disabled or not included.
- The configured reward UUID route existed, but not-yet-configured programme types did not share the complete overview or a specific create destination.

Evidence:

- `v136-grow-streamline/desktop-before.png`
- `v136-grow-streamline/mobile-before.png`

## Required green-state acceptance

1. One compact, single-column task flow with exactly one primary Set up/Continue action.
2. **All reward programmes** immediately follows and includes configured and not-yet-configured earning, individual redeemable rewards, birthday, bring-back, referrals, memberships and gift cards.
3. Every available row has one 44px Edit/Set up action. A configured stable UUID opens that exact reward. A not-yet-configured row opens its exact create control. Disabled/not-included/read-only rows expose no writer.
4. Profitability, journey anatomy and technical tools stay collapsed below the complete overview.
5. Deep-link intent survives refresh and predictable back navigation; no overview click publishes.
6. Desktop 1440px, mobile 390px and 412px have no horizontal overflow. Loading, empty, partial read failure/retry, no-draft, duplicate-name and read-only states are explicit.

## Green-state evidence

Production-component source SHA-256: `0588c88c8787e36a341b111678863778822a6df01b9a68d1a92315b222422b20`.

- The owner view has exactly one primary automatic-setup action and one vertical list across all seven families: earning, every stable-ID redeemable reward, birthday, every stable-ID Bring-back rule, referrals, memberships and gift cards. The browser fixture shows eleven rows because it contains two distinct Bring-back rules.
- Configured, paused, available, not set up, unavailable and not-included states are labelled separately. An absent module renders an article with no button/link; the eleven-row read-only fixture receives only articles and zero setup/edit writers.
- Duplicate **Signature reward** rows retain distinct UUIDs. Selecting the second UUID opens and focuses that exact draft record, changes the hash to `#/loyalty/draft-v2/reward~22222222-2222-4222-8222-222222222222`, and reload restores the same record and input focus.
- Bring-back rules are also individual stable-ID rows. Selecting **Glow regular return** creates/resumes one editable draft only after the existing three-step confirmation, opens the real production Retention renderer with that exact rule in `#rn`, and persists `#/retention/draft-v2/program~bring-back-1` across refresh. The second paused rule opens its own value, while an unknown ID renders an explicit missing-rule warning, never falls through to a blank New program form, and hides all quick-template and rule actions that cannot safely be wired on that stale route.
- Available standalone programmes use exact routes: `#/referrals/fe`, `#/memberships/mn` (or `#/memberships/plist` when configured), and `#/giftcards/giftCardEnabled`. The corresponding production pages consume the routed control ID after rendering.
- Empty-programme browser acceptance labels earning, redeemable rewards and birthday **Not set up**. A partial referral read labels only that row **Unavailable** and shows **Retry programme overview**; it does not misstate the programme as off.
- Configured-but-disabled states are distinct from missing setup: paused bring-back rules, referrals and membership plans display **Paused**, while disabled gift-card sales display **Off**. An active future-dated Bring-back rule displays **Scheduled** with its Singapore start date instead of incorrectly claiming to be live before the customer projection includes it. A synthetic all-engine read failure renders all seven family rows **Unavailable** with no writer.
- A Retention-write owner without Loyalty edit access receives no automatic Loyalty setup action and no dead Bring-back writer; each rule identifies **Loyalty edit access required** because the governed Retention editor shares the Loyalty configuration draft. With the required access, a not-yet-configured Bring-back row opens the confirmed draft directly at the blank New program editor and persists `#/retention/draft-v2/new`.
- The advanced journey, profitability and technical controls remain closed below the complete overview.
- Chrome acceptance passes at 1440×1100, 390×844 and 412×915 with zero horizontal overflow and every row at least 44px high (observed minimum: 72px).
- The strict control inventory decreases intentionally from 269 to 268 literal controls because the competing header-level **Add reward** button is removed; its exact create action now lives in the redeemable-rewards row.
- The automatic setup regression still proves open/cancel zero writes, one idempotent draft-only confirmation, retry with the same key, existing/concurrent draft resume and no publication writer.
- The complete automated gate passes **1,410/1,410** tests. Static build validation passes all six app entry points, and the strict module/control inventory reports 29/25 mapped business modules, 9/9 platform modules, 268 buttons plus 21 links, with zero unlabeled, unwired, invalid, hidden-route or non-semantic controls.
- The source-bound V104 promotion acceptance was recaptured after the shared stylesheet changed and passes desktop 1440px plus mobile 390/412px under source `cf767bb50a8f5c2b71c077c18d8b8e6a469534d815a05cead103997342a6ff5a`; this prevents unrelated customer promotion regressions from being hidden by the Grow redesign.

Green artifacts:

- `v136-grow-streamline/desktop-after.png`
- `v136-grow-streamline/mobile-after-390.png`
- `v136-grow-streamline/mobile-after-412.png`
- `v136-grow-streamline/manager-after-390.png`
- `reward-overview-owner-browser/owner-exact-reward-editor-desktop-1440.png`
- `reward-overview-owner-browser/owner-exact-bringback-editor-desktop-1440.png`
- `tests/business-ui/v136-grow-streamline.test.mjs`
- `tests/browser/verify-reward-overview-owner.mjs`

This is local source and production-component browser evidence. No programme was published, no production data/configuration was changed, and authenticated target owner → staff → customer persistence remains outside this presentation-only phase. Sol independently accepted frozen candidate `e3917c64f46c43564b157b276215aa71e4f3107d7703e7fe3b11ca6bf48473be` with P0/P1/P2 all zero.

## Independent review history

Sol rejected the first moving candidate after reproducing misleading configured-off statuses, unavailable reads shown as not set up, and a dead Retention-only action. Sol rejected the first frozen replacement because its aggregate Bring-back link reached a stubbed `#rn` in the harness rather than the real production editor or a stable rule ID. Sol rejected the next frozen candidate because a stale Bring-back ID hid the form but left seven enabled quick-template and rule controls without handlers. Sol rejected the fourth candidate because an active future-dated Bring-back rule was incorrectly labelled **Live** before it could appear in the customer projection. All four review rounds remain recorded as rejections. The fifth frozen candidate extracts the complete production `retentionPage` into browser acceptance, renders every stable Bring-back ID separately, proves existing/new/missing-ID behavior, removes the Retention-only dead writer, suppresses every inapplicable action on a stale ID, asserts that the stale-route view has no visible enabled button without a handler, and proves future rules are **Scheduled** with their start date. Sol independently reproduced those cases and accepted the exact frozen source/digest with P0/P1/P2 all zero.
