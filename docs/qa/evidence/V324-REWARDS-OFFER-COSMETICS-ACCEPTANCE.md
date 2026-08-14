# V324 — the cosmetic half of the owner's 2026-08-14 evening markup

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Base: `main` @ `b847691` (v322 — the six owner rulings)
Production-component source hash: `ed75a2b1f7ef8d4d2a2035a8d1d4a835d6f820736625cbd6d7acad744ebfa250`

**Client-only. No migration, no RPC, no schema change.** The `nestly_vNNN` migration namespace is
untouched by this work; v324 is a version number for the client change only.

## Addendum — a second owner request, same session

After the first eight-screenshot pass shipped, the owner marked up a live v322 screen (the
Rewards Programme page's "What customers can use right now" switches, R6's own feature) and asked
for one thing: **pressing Turn on/off should pop up a confirm/cancel, not refresh the entire
website.**

The confirmation itself was not missing — v322 already built it, inline on the row, by design
("no modal, which is the standing rule for this surface"). What the owner was reacting to is that
*opening* it did `growSwitchPendingV322=kind;growRerenderV322()` — and `growRerenderV322` is
`growPage()`, which wipes `outerMain` to a loading skeleton and re-fetches
`growOverviewSnapshot()` from the server before repainting the whole Programmes page. Two clicks
that change nothing on the server — open the confirm, then Cancel it — were each paying for a full
network round trip and a visible flash. That is "refreshing the entire website."

**Fix:** the confirm `<li>` for every row is now always in the DOM, `hidden` unless it is the
pending one (`app/app.js`, `growProgrammeSwitchPanelV322`). Opening or cancelling toggles that
attribute directly (`growSwitchSetOpenV324`, `app/app.js`) — no network call, no re-render.
**Confirming is unchanged**: that click still does the one real `writeProgrammeSwitchesV314` call
and still re-renders from the server's reply afterward, because it is the one moment where the
server state — and therefore the rest of the page — actually changed.

**A real bug caught only by driving an actual click in real Chromium, not by reading the diff:**
the confirm `<li>` is a direct child of `.grow-setup-rewardlist-v301`, and that list's own
`.grow-setup-rewardlist-v301>li{display:flex}` rule is an *author* rule — it wins the cascade over
the UA `[hidden]{display:none}` sheet regardless of specificity. The first render of this fix had
the `hidden` attribute landing correctly and doing nothing: all four confirm rows sat open on
screen from page load. `app/index.html` now carries
`.grow-setup-rewardlist-v301>li[hidden]{display:none!important}`, matching the pattern this file
already uses everywhere else it mixes `hidden` with a flex/grid list
(`.grow-programme-row[hidden]`, two lines below it, is the same fix for the same reason).

**Verified two ways.** Source-level: `V324 opening or cancelling the confirmation never calls
growRerenderV322`, `V324 growSwitchSetOpenV324 toggles hidden on every row`, `V324 confirming the
switch is UNCHANGED`, `V324 the hidden attribute is not silently lost to the row list's own flex
layout` (`tests/business-ui/v322-owner-rulings.test.mjs`) — 35/35 pass in that file. Behavioural:
the real `growProgrammeSwitchPanelV322` markup and the real click-wiring block, both lifted
verbatim from `app/app.js`, mounted in a page carrying the real production `<style>` and driven
with actual Playwright clicks in Chromium — a render counter confirmed it stayed at 1 through
"open confirm" and "Cancel", `computedDisplay` on the confirm row was `flex` before the CSS fix and
`none` after, and focus lands on Cancel when a row opens. Scratchpad-only, not checked in.

## Addendum 2 — the wizard's own control was borrowing the wrong word

The owner then repeated, on a clean (unmarked) screenshot of the setup wizard's Programmes step,
a rule already stated once for that same screen: **selecting or deselecting a programme here is
not the same as turning it on or off for customers — it is choosing which programme this session
edits.**

The behaviour was already correct and independently verified: the click handler
(`data-grow-setup-switch-w6i2`) only mutates the wizard's local `state.switches` and re-renders —
no `sb.rpc`, no `sb.from`, no write of any kind — and the publish function
(`programmeScopeSwitchesV322`, `app.js:909`) builds its payload by iterating only the KEYS present
in scope; an unticked kind is never in the object at all, so it can never be sent as `false`. That
is the R6 defect fix, already covered by 35 tests in `v322-owner-rulings.test.mjs`.

What was NOT correct, on inspection: the control's `role` and its state pill. It was
`role="switch"` with a pill reading **ON**/**OFF** — the literal ARIA role for "a control with
immediate live effect" and the literal word the ACTUALLY live control (the Programmes page's
`data-grow-switchtoggle-v322`, one page over) uses for "customers can use this right now". Two
controls, three clicks apart, reading identically while meaning opposites — exactly the confusion
the owner's rule exists to prevent, even though the paragraph of copy beneath the tiles already
said as much in words.

**Fix:** `role="switch"` → `role="checkbox"` (independently pickable, not exclusive — the same
property the role change protects, without the "live now" implication); pill text `ON`/`OFF` →
`Selected`/`Not selected`. The internal `data-grow-setup-switch-state-w6i2` attribute values are
unchanged (`on`/`off`) — nothing reads them as a live fact, so relabeling them would be churn.

Both pinned tests updated with the reasoning inline (`v301-programmes-setup-wizard.test.mjs`,
`w6i2-programmes-home.test.mjs`) — 113/113 across the three affected files. Full suite 2999: 2998
pass, the one known env-bound failure.

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

**Suite (final, both passes): 2999 tests, 2998 pass, 1 fail.** The one failure is the known
env-bound `tests/mobile` store-readiness check (no `node_modules/@capacitor` in a fresh worktree),
which reproduces identically on an untouched `main` worktree and is unrelated to this change.

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
  `99c3c0b40aeac7cff1d32fe6a2909d246571caa239948162c5f4fd8f9907793f`. CTA heights ≥44px and the
  no-horizontal-scroll assertions hold at 1440 / 390 / 412.
- `v142-connect-paynow` — source hash `d94288b8bef85c32ab2bee103bb738c9371dbfafbce6218b1dd68c604f7ab80b`.

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
