# V319 — Rewards & Offer acceptance

Date: 2026-08-14
Branch: `codex/v319-rewards-and-offer`
Base: `origin/main` @ `5bca979` (the build the owner marked up: footer read `5bca979f0990 · production`)
Requirement: `REWARDS-OFFER-319`
Production-component source hash: `85a6b8ed4d95ec87c35ff550b7a7600ba6786c9711f8bd1628c1f2dcf610e532`
Migration: **none.** Client-only. No RPC, table, policy or cron object is added, altered or dropped.

## What the owner asked for

Three iPad markups of 2026-08-14, all against build `5bca979f0990`.

**1 — Customer profile (`#/client/…`, screenshot of "Mumu").**
"300" written large against the Points System row with **"expires in xxx"** beside it. On the
summary card opposite, three rows struck through: **Points 300**, **300 points expire 20 Sep
2026**, **Spendable credit SGD 0.00**. The two promotion rows ringed together, with an arrow and
the note **"these are Ads Promotion, put in different box"**.

**2 — Programmes (`#/grow/overview`).**
"PROGRAMMES" struck out of the rail with **"Rewards & Offer"** written above it. "List" struck
out with **"Rewards Programme"** written, and a new **"Limited Offer"** bullet added beneath. Over
the Overview table, a two-column frame headed **"Rewards & Loyalty"** and **"Limited Offer"**, with
**"two side view"** and **"these two are different categories"**. Of the two promotion rows:
**"these two are current promotion after that is shown in customer app/side. editable in this tab"**.

**3 — Dashboard (`#/dashboard`).**
The whole period strip (Today / 7d / 30d / 90d / date range / Apply) ringed in the page titlebar,
with an arrow drawn down to the Performance card: **"filter time move here"**.

## What shipped

### 1. Customer profile

| Before | After |
| --- | --- |
| `Points System · 300 points · 700 more for Free Facial cream` | `Points System · **300** points · expires 20 Sept 2026 · 700 more for Free Facial cream` |
| Summary card: Points 300 (+ expiry line), Spendable credit SGD 0.00 | both rows gone — see the rules below |
| Promotions listed inside "Available Customer Programmes" | own card, **"Limited offers · Current promotions everyone can use"** |

Three judgement calls are recorded here because they are not literal transcriptions of the markup:

- **The points row is dropped only when a programme row took it over.** A tiers-only firm renders
  no Points System row, and a firm with no programme renders no row at all. In those cases nothing
  moved, so the summary row stays — otherwise those owners would lose the balance *and* the points
  history with it. Same for an unreadable loyalty facet.
- **The balance stays clickable.** V259 was raised because the number was "not clickable to see
  where the points came from". Moving it must not undo that, so the balance on the programme row
  *is* the `#c360PointsHistoryV259` control, and exactly one such control exists per render.
- **Spendable credit is hidden at zero, not deleted.** Unlike points it is duplicated nowhere — it
  was simply `SGD 0.00` occupying a row on a profile that has never held credit. The row returns
  the moment the customer actually holds money, which the counter cannot be allowed to miss, and
  the figure is always one tap away under *Balance and earning*. (Evidence screenshot shows the
  row present, because that fixture customer holds SGD 15.00.)

A partial expiry reads `· 120 points expire 20 Sept 2026` rather than `· expires …`, so a slice
expiring is never mistaken for the whole balance going.

### 2. Rewards & Offer

- Rail group `Programmes` → **`Rewards & Offer`**; child `List` → **`Rewards Programme`**; new
  child **`Limited Offer`** → `#/grow/offers`. Module gating (`items:`) untouched — a rename must
  not change who can see the group.
- The page heading and the breadcrumb kicker follow the rail, per V245's own rule that the nav row
  and page heading say the same words.
- `offers` is a real view (`programmeView`, `hashParamIsProgrammeView`, `growCategoryViewV271`,
  and the rail's active-state predicate), so it is linkable and back-button-safe like its
  siblings — and renders **only** the promotions category. Without the `growCategoryViewV271`
  entry it would have fallen through to `topicOnV229`'s "no tiles, no drilled topic" branch, which
  answers true for every key: the Limited Offer page would have rendered the whole module.
- The promotions category is now **one** definition (`growLimitedOfferCategoryHtmlV319`) rendered
  from two entry points — the drilled topic and the new tab — rather than two copies that drift.
  Every row keeps its owner-gated `#/promotions/<id>` Edit destination ("editable in this tab").
- Overview splits into two tables by the entry's own type. The offers table **drops "Customers
  used"**: nothing in the schema records a customer redeeming a promotion, so that cell was
  "Not tracked" on every row without exception. It gains **"Ends"**, read from the same `ends_at`
  `promotionLifecycleV186` judges the row's state by; an open-ended offer says "No end date"
  rather than borrowing a count's "Not tracked". `entry.ended` is untouched, because History's
  "Ran until" column must not print a future date.

### 3. Dashboard

The strip moves into the Performance card header, beside the period line it rewrites and before
Minimise. Same ids (`df` / `dt` / `apply`), same `.qbtn[data-d]` set, same `.dashboard-range`
container — every handler already resolved them through `dashboardRoot`, which contains the new
position exactly as it contained the old one. It sits **outside** the collapsible body on purpose:
minimising Performance hides the figures, and a control that vanished with them would strand the
schedule day this strip also moves (V295's two-way link).

## Verification

### Suite

`npm run validate` — see the run log below. Known-good baseline carried forward: one
environment-bound failure only, `tests/mobile/v131-store-publication-readiness.test.mjs`
("missing dependency privacy manifest: node_modules/@capacitor/ios/…"), which fails identically
on `origin/main` in this environment.

New: `tests/business-ui/v319-rewards-and-offer.test.mjs`, 18 tests. These **evaluate the shipped
source** and assert what it emits, rather than grepping `app.js` for the lines they were written
against — W6 increment 2 shipped four inert toggles and a silently re-based tier ladder past
nineteen green source pins (see `docs/design/…` and the memory note on vacuous source pins).
Covered: the expiry phrase at whole / partial / absent; the four states of
`balanceProgrammeRowV319`; that a paused note is a *sibling* of the copy paragraph and not a `<p>`
inside a `<p>`; that the row builder still escapes every caller that did not opt into markup; the
two-category split, both empty states, and the dropped count; the rail contract; single-definition
rendering; and that exactly one period strip, one `#df` and one `#apply` exist on the dashboard.
Plus a `dataset.X` ↔ emitted `data-*` casing sweep over the three attributes this wave adds.

Existing suites retargeted rather than deleted, each with the reason in place: V138, V145, V154,
V164, V172, V173, V180, V227, V245, V250, V259, V268, V271, V301. Two of those changes are worth
naming, because both were assertions passing for the wrong reason:

- `v227` compared category order by *source* position; the extracted promotions category no longer
  sits after Lifestyle rewards in source, though it still renders after it. The boundary now comes
  from the render site.
- `v227`'s div-balance check sliced between two points that both landed *inside* a
  `<div class="programme-category-title">`, so two unopened `</div>` at the front cancelled two
  unclosed `<div>` at the back. It would have stayed balanced through a genuinely unbalanced edit.
  Both ends are whole tags now.

### Real browser

`tests/browser/verify-v296-programmes-batch-walkthrough.mjs` — the real production bundles
(`app/index.html` + the stamped chunks) through the real router in Chrome, Supabase replaced by an
in-page fixture. **PASS, steps 1–8**, step 8 being V319: the rail title and all four children, the
Limited Offer tab rendering `["promotions"]` and nothing else, both Overview categories with the
promotion filed under exactly one of them, the two columns measured side by side at 1440px
(tops `[354,354]`), exactly one period strip and it inside `.performance-heading`, and 7d still
moving the Performance period after the move.

Step 1 was retargeted, not weakened: the promotion row it asserted is now looked for in
`#c360-offers-v319`, where the owner asked it to go, and the step gained the expiry assertion. The
fixture's `expiry` was `null`, which meant no step could ever have seen the expiry line; it now
carries the owner's own tenant shape (300 points, all expiring 20 Sep 2026).

Screenshots, captured in the same run that asserted the above so they cannot describe a different
tree — 1440 and 390 for each:

- `v319-customer-profile-{desktop-1440,mobile-390}.png`
- `v319-programmes-overview-{desktop-1440,mobile-390}.png`
- `v319-limited-offer-{desktop-1440,mobile-390}.png`
- `v319-dashboard-performance-{desktop-1440,mobile-390}.png`

Chrome evidence re-captured for the fixtures whose source hash moved with the shared stylesheet:
`verify-v104-promotions-visual.mjs` (PASS, `97f873b7…`) and `verify-v142-connect-paynow.mjs`
(PASS, `a093c4a0…`). Both were served from **port 4319 / 4396**, not 4173 — another worktree holds
4173, and evidence has been captured from the wrong tree that way before.

## Not done, and why

- **No migration.** Nothing here needs one. In particular the promotions surface is unchanged
  server-side; only where it renders moved.
- **The Limited Offer tab reuses the existing promotion editor** (`#/promotions/<id>`). The owner
  wrote "editable in this tab", and the rows are — through the editor the module already has. A
  new inline editor was not built, because that is a different request.
- **The customer-facing app is untouched.** The owner's note "shown in customer app/side" is a
  statement of what already happens (`business_customer_content_v95`), not a change request.
