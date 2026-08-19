# Handoff — Peekaa UI standard work (2026-08-18)

Written so a fresh session can pick this up cold. Read this first, then
`docs/design/PEEKAA-UI-STANDARD.md` for the operating manual.

**Branch:** `claude/peekaa-ui-ux-audit-lhaa4o` — pushed, nothing deployed.
**Head at handoff:** `92ce739` (+ this doc and the regen script).
**Base:** `7721a49`.

---

## What happened, in order

1. The owner asked for a **read-only UI/UX consistency audit** of the Peekaa
   business workspace and customer app — terminology, ON/OFF controls, buttons,
   alignment, typography, colour, status badges, component reuse, and the two
   apps compared. Explicitly: report first, change nothing.
2. The audit was done by static analysis of `app/app.js`, `app/index.html` and
   `app/customer-ui.js`. **`app-business.js` / `app-customer.js` / `app-core.js`
   / `app-auth.js` / `app-i18n.js` are generated splits of `app/app.js`** and
   were not audited separately — never edit them directly.
3. Before the report was written the owner redirected to *"proceed to fix,
   ensure only cosmetic"*. That produced `fb53345` — a CSS-only pass.
4. The full report was then written and published as an artifact.
5. The owner ruled on all six open decisions. Those became six commits.

---

## The six rulings, as shipped

| # | Ruling | Commit |
|---|---|---|
| 1 | Brand red is **#C24135** (was two reds: business #C24135, customer #F06A4F) | `b0eabf9` |
| 2 | Retire `window.confirm()` — one styled confirm | `a4de29c` |
| 3 | Terminology standard: Delete vs Remove, Turn on/Turn off, "Add reward" | `c2c5c36` |
| 4 | Status vocabulary on three axes | `a234051` |
| 5 | Two shell breakpoints (768 compact, 960 rail) | `23119f8` |
| 6 | Module icon on every page header | `0151e6b` |

Plus `fb53345` (earlier cosmetic CSS pass) and `92ce739` (the standard doc).

Each ruling routes through **one** definition so it can be changed in one edit —
`--brand-red`, `STATUS_WORDS`, `confirmActionV386`, the breakpoint block. See the
standard doc for anchors and revert order.

---

## Workflow facts that will cost you time if you don't know them

**Fixtures embed the production CSS.** Eight files under `tests/browser/` carry a
verbatim copy of the stylesheet plus a SHA-256 of the source. Two tests compare
against captured Chrome measurements. Any CSS or render-function change makes
them stale, and the failure reads like a real bug ("must come from current
production source").

```sh
npm run bundle-stamp                             # only if you edited app/app.js
node scripts/quality/regen-visual-fixtures.mjs   # then this
npm test
```

**Playwright is not a dependency.** Install it without touching the manifests:

```sh
npm install playwright --no-save --no-audit --no-fund
# Chromium already present at /opt/pw-browsers/chromium-1194/chrome-linux/chrome
```

**Two fixtures were already stale before this work** —
`reward-overview-owner-visual.html` and `v181-onboarding-board.html`. Their tests
don't assert byte equality so they pass either way, but regenerating them sweeps
~400 unrelated lines into your diff. The regen script restores them to HEAD.
Worth a separate look someday.

**v142 evidence always shows a diff.** Its capture mints fresh idempotency UUIDs
each run. If `git diff` on
`docs/qa/evidence/v142-connect-paynow-pos/metrics.json` shows only
`*_idempotency_key` changes, revert that directory.

**Baseline test state — 3 failures, all pre-existing on `7721a49`:**

- `W6I2 E3 turning Referral OFF disables referral_programs`
- `every discovered writer identity is accounted for in the registry`
- `every value-impacting discovered identity is a curated writer`

A fourth (`store association generator fails closed`) is order-dependent in the
full run and passes in isolation on both the base and this branch. **Anything
beyond these four is yours.** Verify by stashing and re-running before assuming
a failure is pre-existing.

**Five test files execute code sliced out of `app/app.js` via `new Function`**
(`v180`, `v259`, `v271`, `v319`, `v326` under `tests/business-ui/`). Adding a new
top-level helper to `app.js` puts it out of their scope and they fail with "X is
not defined". The fix used here: have the harness slice the *real* definition out
of `app.js` (see `STATUS_PRELUDE_SRC` in `v319`/`v326`) rather than restating
values in the test, so a test can never drift from the app.

**Module labels double as i18n keys.** `WORKSPACE_COPY_V97` uses the English
string as the key. Renaming a label orphans its zh-CN / Malay translation. The
workspace tables cover **zh-CN and Malay only**. Two interpolation inventories
(`WORKSPACE_INTERPOLATED_UI_INVENTORY_V97` and
`..._ATTRIBUTE_INVENTORY_V97`) plus a count gate in
`tests/customer-wallet/v97-workspace-localization-acceptance.test.mjs` must be
updated together when adding a template.

---

## Corrections to the published report

Two claims in the artifact were wrong; the repo is correct.

1. **Page-header icons.** The report blamed `.v150-titlebar` vs `.cui-page-head`.
   All five `.v150-titlebar` screens already had icons. The real gap was a
   **third** pattern — a bare `.topbar` on 13 screens. Count was right, cause
   wasn't. Fixed correctly in `0151e6b`.
2. **Before/after images** in chat were labelled "commit 6B8FEF4". That hash is
   fabricated; the real base is **`7721a49`**.

---

## Known cost of ruling 3

"Turn on" / "Turn off" have **no zh-CN or Malay translation** and fall back to
English — as they already did in Grow. Ruling 3 widened that slightly by using
them on Services, bundles, Products, membership plans, booking types and
Retention. These need a native speaker, not a guess. The Delete/Remove split did
get proper translations by reusing the verified `Delete` strings already present.

---

## Render sweep (18 Aug, `6f7679e`)

`tools/qa-sweep/` boots the real app against a Supabase test double and sweeps
46 routes. It found and fixed two defect classes:

- **11 tap targets under 44px** — 5 were a miss in the earlier 44px pass
  (Dashboard affordances classified as "inline links" without measuring; the
  customer app never covered). Note the schedule chip needed the *anchor*
  raised, not its wrapper.
- **2 unguarded `sgt()` calls** — `sgt()` returns null for a falsy date and
  both sites called `.slice()` on it.

Four candidates were checked and **dismissed** — see the artifact. The one to
remember: a `data-*` "dead handler" scan returned 55 hits, nearly all false
because selectors are built from template literals. That whole pass was
discarded rather than reported.

**The sweep proves nothing server-side.** 407 rpc + 226 from + 63 auth calls
are stubbed. Auth, RLS, the ledger, payments, realtime and the
business↔customer interaction remain untested and need a QA tenant.

---

## What to pick up next

In the order recommended in the audit. The first two are **Must-fix** items from
the report that no decision was taken on.

1. ~~**Money column alignment.**~~ **DONE** — `a3acb9a`. Every money cell and its
   header now uses the shared `.num` helper; `th.num` was added to the rule and
   the plain responsive table's stacked label pinned left.
2. **KPI tiles — HALF DONE.** The load jump is fixed: each skeleton is now sized
   to the tile that replaces it (Dashboard was +17px, Waitlist −37px, P&L +6px;
   all three now 0). **Still open:** the three implementations themselves —
   `.card.kpi`, `.card.kpi.v150-kpi`, `.dashboard-metric.kpi`. Collapsing them to
   one needs an owner decision on which tile wins, because Dashboard's is a
   clickable button with an arrow and action label while the others are static.
3. **`CUI.status` / `CUI.field`.** Still zero uses against 177 hand-written
   pills and ~58 hand-written forms. Ruling 4 fixed the *words*; the *component*
   consolidation is open, and it is the root cause of the pill drift.
4. **Colour: 211 hex → ~28.** Ruling 1 fixed the brand red. Still open: ~32
   near-identical warm tints, five greens, and renaming the token sets to
   `--biz-*` / `--cust-*` so the business/customer split is explicit.
5. **Typography.** ~61 distinct font sizes; the proposed 7-size scale
   (11 / 12.5 / 14 / 15 / 18 / 22 / 30) is not implemented.
6. **Spacing.** `--space-1…6` are defined and used **zero** times.
7. **Components.** 10 modal implementations, 4 mobile gutter conventions, 6+ tab
   implementations, 23 icon sizes.
8. **Customer home surface.** The `-v343/344/346` series is 333 of the 400
   version-suffixed classes and holds nearly every selector declared 3+ times.
   Biggest single win — do it **last**, once the tokens above are settled.

---

## Ground rules that applied throughout

- `app/app.js` is the only editable source; run `npm run bundle-stamp` after
  touching it.
- Gates before every commit: `npm run quality`, `npm run bundle-stamp:check`,
  `npm test`, `npm run build`.
- Tests that locked old values were **updated, never weakened** — every
  assertion kept its intent, and the WCAG contrast gate was taught to resolve
  token aliases rather than have its thresholds relaxed.
- Nothing here is deployed. Production is Supabase `gadpooereceldfpfxsod`.
