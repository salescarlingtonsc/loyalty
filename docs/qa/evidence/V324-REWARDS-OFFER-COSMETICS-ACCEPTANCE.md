# V324 — the cosmetic half of the owner's 2026-08-14 evening markup

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Base: `main` @ `b847691` (v322 — the six owner rulings)
Production-component source hash: `ca8282b83ef9b6f6e031636fc218b717114a7f9995a1571e363f55a5aed1939b`

**Client-only. No migration, no RPC, no schema change.** The `nestly_vNNN` migration namespace is
untouched by this work; v324 is a version number for the client change only.

## Why this is a separate change from v322

The owner marked up eight screens of build `8d44f4618ed1` (v320) on 2026-08-14. Those marks split
cleanly in two, and the split is the reason this document exists:

- **Behaviour** — referral payout, stamps exclusivity, the wizard's scope, the stamp-card
  milestone list. Shipped as **v322** (`b847691`) by the session that owned that surface.
- **Presentation** — what this change is. No control changes what it does; no row changes what it
  means; nothing new is read from or written to the database.

Marks that are neither, and are **deliberately not built here**, are listed at the end.

## What shipped, mark by mark

| Owner's mark | Screen | Change |
|---|---|---|
| "add background box, easier to see" (ringing all three steps) | Promotions editor | `.promotion-studio-progress` becomes a card-surfaced box with a hairline border; each step keeps the page tint inside it |
| TYPE column struck through | Overview | Column removed from the rewards table |
| "those reward is under point system" (reward row ringed) | Overview | Reward rows indent under the programme row above, with an elbow rule |
| "delete these unnecessary wordings" | Overview | Both column notes removed |
| ringed "+" beside each heading | Overview | An add control per column — rewards → `#/grow`, offers → `#/grow/offers` |
| "separate them" (line drawn between the columns) | Overview | Divider between the two columns, at the width where they are actually side by side |
| "all date use dd/mm/yyyy format" | Overview, History | `promotionDateShortV324` on both date columns |
| page title struck, "Overview" written | Overview | Subtitle and the duplicate card kicker removed; `<h1>` and the view's `<h2>` remain |
| "history UI/UX follow overview" | History | History renders through the **same** frame function as Overview |
| "don't need this" across WHY IT STOPPED | History | Column removed |

### Two judgement calls, stated rather than buried

**The Type column carried something.** It was the only cell saying how a reward related to the
programme above it. Deleting it outright would have left two rows reading as siblings when one
belongs to the other — which is the opposite of what the owner's other mark on the same table
asked for. The indent replaces it, and it is scoped by the row's own type (`Reward`), never by a
hard-coded parent: a stamps firm's milestones (v322 R5) must not start claiming to sit under
"Point system".

The indent also has to be **earned by a row above it**. The first render of this change indented
all three rows on History — a firm that retires rewards but never retires its points programme
produces a table of nothing but children, and the elbow then pointed at a parent that was not on
the screen. `growOverviewNameColumnV324` now takes the row list as well as the row and draws the
indent only when a non-child row precedes. That is why the Programme column is built by a helper
rather than the inline `['Programme',row=>…]` pair the older suites asserted on.

**`promotionDateShortV324` is a second formatter, not an edit to the first.** The owner wrote "all
date", but "all" spans a dozen per-feature helpers across every surface in the app — including
three other sessions' — so changing them under an unattended cosmetic pass was not a call to make
here. This change covers the tables the arrow actually points at. **The rest of the app still
renders the long form, and that inconsistency is real and open** — see "Left for the owner".

Both formatters resolve the same instant: a bare `yyyy-mm-dd` is anchored at **noon** Singapore,
so a date can never fall back a day on a browser west of SGT.

## Verification

**Suite: 2994 tests, 2993 pass, 1 fail.** The one failure is the known env-bound
`tests/mobile` store-readiness check (no `node_modules/@capacitor` in a fresh worktree), which
reproduces identically on an untouched `main` worktree and is unrelated to this change.

**Ten pre-existing tests went red and all ten were source-text assertions**, not behavioural ones —
they pinned the exact source of what the owner has now struck out (the `Type` column literal, the
subtitle string, the kicker ternary, `promotionDateTextV104` inside the date cell, and the
`growOverviewTableV271` template that is now a function call). Each was re-pointed at the new
intent with the reason recorded inline; **none had its behavioural assertion weakened**, and the
four `v319-rewards-and-offer` cases still render real HTML from the shipped source and assert
against it.

**Six new behavioural tests** pin what this change actually does, so it cannot silently regress:

| Test | Pins |
|---|---|
| `V324 a reward reads as belonging to the programme above it` | child indented, parent NOT — read from the two rendered `<td>` cells |
| `V324 with no programme above it, a lone reward is not indented under nothing` | the History case above |
| `V324 a promotion is never indented` | the child rule is scoped to rewards |
| `V324 each column heading carries its own add control` | both hrefs, and a worded `aria-label` on each |
| `V324 the Started column is dd/mm/yyyy, on both categories` | new format present, long form absent |
| `V319 … drops a count nothing records` (extended) | `31/08/2026`, and the Type column's absence |

**Browser evidence re-captured in real Chromium**, not hand-edited — both harnesses re-run and both
report `PASS` with the current source hash:

- `v104-promotions-*.png` + `v104-promotions-production-render-metrics.json` — source hash
  `a4b956d423960aec0e942e674fe39f7cc105eb89ff7c2eab45f2379e22776670`. CTA heights ≥44px and the
  no-horizontal-scroll assertions hold at 1440 / 390 / 412.
- `v142-connect-paynow` — source hash `19fc53349acbad41781bc01dd4959d77ee31b3c5325315e66d2d92787d86e7ec`.

**What the v104 capture does NOT cover, stated because the name invites the assumption.** It
renders the CUSTOMER-facing offers list and its terms modal — it re-ran green here because it
embeds production CSS, not because it exercises the business Promotions editor. **No checked-in
harness renders `.promotion-studio-progress`.** The step-strip box was verified by rendering the
shipping `<ol>` markup, lifted from `app/app.js` rather than retyped, inside the production
`<style>` and screenshotting it in the same Chromium — confirming the strip now reads as a
surfaced box against the page tint. That render was scratchpad-only and is not checked in, so
**this mark has no regression test**: it is CSS on a class no suite asserts against. A harness
covering the promotions editor would be the right follow-up, and is not in this change.

Nine `tests/browser/*.html` fixtures regenerated from their own generators (they embed production
CSS byte-for-byte, so a CSS change necessarily restamps them).

Bundles rebuilt with `npm run bundle-stamp` — the split bundles and the `index.html` fingerprints
are consistent, per the standing rule that `/app.js` is CDN-pinned for four hours.

## Left for the owner — named, not implied

These are on the same eight screenshots and are **not** in this change. Each is behaviour, not
presentation, and belongs with whoever owns that surface next:

1. **"can add button to republish"** (History) — a new write path; History has no such action today.
2. **"just directly go creation page after creation"** (Limited Offer) — routing.
3. **"can see history expired gift"** and "once removed, removed from here" (wizard, Gifts step) —
   the wizard is v322 R6's surface.
4. **The Rewards Programme restructure** — v322 R6 already put a per-programme on/off control on
   that page; what remains of the sketch should be judged against what R6 shipped, not against the
   v320 screenshot.
5. **Customer profile** — points count on the programme row, clickable offers, "ends in xxx",
   "put some logo". `codex/v323-customer-beautify` is live in that surface.
6. **dd/mm/yyyy everywhere else in the app** — see above. This is a shared-formatter change that
   crosses every surface and wants its own pass.
7. **"all published rewards & offer still editable"** — a requirement about edit affordances, not a
   restyle.
