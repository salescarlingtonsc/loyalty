# Handoff — Peekaa UI/UX audit branch

Written so a fresh session can pick this up **cold**. Read this first, then
`docs/design/PEEKAA-UI-STANDARD.md` for the operating manual (control points,
revert order, fixture regeneration).

| | |
|---|---|
| **Branch** | `claude/peekaa-ui-ux-audit-lhaa4o` — pushed, **nothing deployed** |
| **Base** | `7721a49` |
| **Head** | `d6eeed7` (19 commits) |
| **Diff vs base** | 64 files, +3858 / −1443 |
| **Test suite** | 3157 tests, **3154 pass, 3 fail** — all three pre-existing on the base |
| **Production** | Supabase `gadpooereceldfpfxsod`. Never `kyzovonwnscrzmkvocid` (retired) |

**The three baseline failures**, so you can tell yours from ours:

- `W6I2 E3 turning Referral OFF disables referral_programs, untouched inputs (defect 3)`
- `every discovered writer identity is accounted for in the registry`
- `every value-impacting discovered identity is a curated writer …`

A fourth, `store association generator fails closed`, is order-dependent in the
full run and passes in isolation on both base and branch. **Anything beyond
these four is yours.** Verify by stashing and re-running before assuming.

---

## 1. How this branch came about

The owner asked for a **read-only UI/UX consistency audit** of the business
workspace and the customer app — terminology, ON/OFF controls, buttons,
alignment, typography, colour, status badges, component reuse, and the two apps
compared. Explicitly: report first, change nothing.

Before the report was finished the owner redirected to *"proceed to fix, ensure
only cosmetic. nothing logic or do not change my app."* That produced the first
CSS-only commit. The report was then written and published, the owner ruled on
all six open decisions, and those became six commits. Later the owner asked for
live testing of *"every exact buttons and features"* on both apps, and finally
for *"a full detailed analysis … so we can go live immediate. Both customer &
business."*

**Cosmetic-only has held throughout.** No logic, no schema, no RPC, no
behaviour change. Everything in this branch is markup, CSS, copy, tests, or the
QA harness.

---

## 2. The six owner rulings, as shipped

Each routes through **one** definition so it can be changed or reverted in a
single edit.

| # | Ruling | Commit | Single source |
|---|---|---|---|
| 1 | Brand red is **#C24135** (was two reds: business `#C24135`, customer `#F06A4F`) | `b0eabf9` | `--brand-red` — `app/index.html:56` |
| 2 | Retire `window.confirm()` for one styled confirm | `a4de29c` | `confirmActionV386` — `app/app.js:2725` |
| 3 | Terminology: Delete vs Remove, Turn on/Turn off, "Add reward" | `c2c5c36` | the copy sites themselves |
| 4 | One status vocabulary on three axes | `a234051` | `STATUS_WORDS` — `app/app.js:511` |
| 5 | Two shell breakpoints (768 compact, 960 rail) | `23119f8` | the anchored breakpoint block in `app/index.html` |
| 6 | Module icon on every page header | `0151e6b` | 22 `.topbar` sites + `CUI.icon` |

Revert order and per-ruling instructions are in
`docs/design/PEEKAA-UI-STANDARD.md` §2. **Order matters in two places** — see
that section before reverting anything.

---

## 3. Every commit on this branch

Oldest first.

| Commit | What it did | Size |
|---|---|---|
| `fb53345` | Cosmetic CSS pass: defined `.btn.primary`/`.btn.secondary` (used in markup, never defined), six controls onto `var(--control-h)`, `.v150-titlebar` matched to `.cui-page-head`, `.v150-kpi` matched to `.kpi`, 25× `border-radius:100px`→`999px`, dropped Fraunces from the font request, added `th.num` | 16 files, +661/−478 |
| `b0eabf9` | Ruling 1 — one brand red, six tokens, all aliases pointed at them | 19 files, +351/−202 |
| `23119f8` | Ruling 5 — two breakpoints; `app/pwa.css` 760→768; customer `min-width:640px`→`641px` to fix a collision | 26 files, +274/−148 |
| `0151e6b` | Ruling 6 — 22 bare `.topbar` headers given a module icon; four hand-written headers 25px→24px | 9 files, +84/−84 |
| `a234051` | Ruling 4 — `STATUS_WORDS` + `statusOnOff()`; 22 availability labels routed through it; `PROGRAMME_STATUS_LABEL_V180` "Ongoing"→"On" | 14 files, +183/−128 |
| `c2c5c36` | Ruling 3 — Enable/Disable and Pause/Resume → Turn on/Turn off; Archive/Retire → Delete; Remove→Delete for record deletions; "Add a new gift"→"Add reward" | 12 files, +71/−65 |
| `a4de29c` | Ruling 2 — `confirmActionV386`; all 28 `window.confirm()` converted; four enclosing functions made async | 16 files, +226/−103 |
| `92ce739` | `docs/design/PEEKAA-UI-STANDARD.md` — the operating manual | doc |
| `8c2f05f` | `scripts/quality/regen-visual-fixtures.mjs` + first handoff | script + doc |
| `a3acb9a` | Audit A5 — money column alignment: 17 money `<td>`s marked `.num`, 22 inline `text-align:right` converted, 9 header rows marked | 19 files, +177/−175 |
| `ef6478a` | Handoff bookkeeping | doc |
| `6cf55a8` | Audit A7 — KPI skeletons sized to the tile that replaces them (Dashboard was +17px, Waitlist −37px, P&L +6px; all three now 0) | 19 files, +120/−54 |
| `cc4bf5f` | QA harness v1: `sweep.mjs`, `sb-double.js`, `null-guard.mjs`, `verify-null.mjs`, `verify-rulings.mjs` | new |
| `6f7679e` | Fixed what the render sweep found: 11 tap targets under 44px, 2 unguarded `sgt()` calls | 21 files, +118/−115 |
| `73c2a0e` | Handoff update | doc |
| `0821fd4` | QA harness v2: `click-sweep.mjs`, `dom-health.mjs`, `xss-sweep.mjs`, `locale-sweep.mjs`; chainable `rpc()` in the double | new |
| `8c688a8` | 63 form fields given accessible names; status-vocabulary translations; Referrals status pair | 11 files, +213/−181 |
| `761d455` | Customer-app fixtures; route-dependent click scope; customer locale wiring | 6 files, +223/−8 |
| `d6eeed7` | Recorded the customer-app locale finding | doc |

---

## 4. The QA harness — `tools/qa-sweep/`

Boots the **real** app (`app/index.html`) in headless Chromium against a
Supabase test double. The app's own render functions run; only the network
under them is faked.

```sh
npm install playwright --no-save --no-audit --no-fund   # not a project dependency
# Chromium is already at /opt/pw-browsers/chromium-1194/chrome-linux/chrome

node tools/qa-sweep/sweep.mjs         # 46 route renders + screenshots
node tools/qa-sweep/click-sweep.mjs   # presses every control on 38 routes  (~25 min)
node tools/qa-sweep/dom-health.mjs    # 38 routes × 3 viewports             (~20 min)
node tools/qa-sweep/xss-sweep.mjs     # output escaping, 38 routes          (~10 min)
node tools/qa-sweep/locale-sweep.mjs  # zh-CN coverage, 30 routes           (~10 min)

node tools/qa-sweep/null-guard.mjs    # unguarded null RPC payload reads (static)
node tools/qa-sweep/verify-null.mjs   # checks those against the SQL
node tools/qa-sweep/verify-rulings.mjs # asserts the UI standard in a real render
```

Each takes a single route argument to run just that one, e.g.
`node tools/qa-sweep/click-sweep.mjs customer/profile`.

**Run them from the repo root.** They resolve `playwright` from
`node_modules`, and a stray `cd` will break them with `MODULE_NOT_FOUND`.

### What each sweep proves

| Sweep | Method | Latest result |
|---|---|---|
| `sweep.mjs` | Loads each route, watches for uncaught errors and blank regions | clean |
| `click-sweep.mjs` | Every button, link, toggle, summary — reloading between each so results are independent. Records JS errors, blanked main, navigation, and whether Escape closes what opened | **604 controls, 0 defects, 46 dialogs opened + closed** |
| `dom-health.mjs` | Duplicate ids, horizontal overflow, controls with no accessible name, unlabelled fields, heading-level jumps — at 390 / 768 / 1440 | clean except 10 latent dup ids |
| `xss-sweep.mjs` | Poisons every user-controlled string the double returns, then asks the page whether any parsed as markup. **Also reports whether the payload reached the screen**, so "clean" means escaped, not absent | **0 injections; payload proven on 35 of 38 routes** |
| `locale-sweep.mjs` | Boots each route with the workspace preference *and* the customer profile set to Chinese, counts what stayed English | business avg 45% (18–67%), customer avg 30% (22–38%) |

### The double — `sb-double.js`

Replaces the supabase-js CDN bundle. Records every call on `window.__QA`
(`rpc`, `from`, `auth`, `unfixtured`), so you can ask any screen what data it
wanted and what had no fixture.

Two things to know:

- **`rpc()` returns a chainable Proxy, not a Promise.** Real supabase-js
  returns a builder, and the customer paths call `.abortSignal()` on it
  (`customerRpc` at `app/app.js:125`). Returning a bare Promise made every
  customer interaction throw.
- **`__QA_LOCALE` drives both apps.** It feeds
  `get_workspace_locale_preference_v97` for the workspace and
  `customer_get_profile.preferred_language` for the customer app.

Unfixtured RPCs resolve to an empty `[]`/`{}` — **never `null`**, which would
crash every call site that reads `data.foo` without a guard and mask every
render defect behind the first throw. That whole class is hunted separately by
`null-guard.mjs`.

### Fixture accuracy is the whole game

Shapes come from the migrations that define each RPC, never from guesses. The
customer fixtures were derived from `c44_actionable_wallet_card` (v44/v45),
`customer_live_loyalty_v384`, `customer_list_programmes_v89`,
`customer_get_booking_requests` (v72), `customer_get_home_offers_v167`,
`customer_get_appointments_page` (v39) and
`customer_get_communication_preferences_v263`.

`db/database.types.ts` is a stale placeholder and **cannot be trusted for
nullability**. Check `db/migrations/`.

---

## 5. Defects found and fixed

### Round 1 — render sweep (`6f7679e`)

- **11 tap targets under 44px.** Five were a miss in an earlier 44px pass
  (Dashboard affordances classified as "inline links" without measuring; the
  customer app was never covered). Note the schedule chip needed the *anchor*
  raised, not its wrapper — raising the wrapper left the `<a>` inside at 29px.
- **2 unguarded `sgt()` calls.** `sgt()` returns `null` for a falsy date and
  both sites called `.slice()` on it.

### Round 2 — DOM health, locale, static (`8c688a8`)

- **57 labels that were not labels.** A `<label>` sat immediately before its
  field with no `for=`, across Services, Branches, Expenses, Rewards, Retention
  and the invite screen. It looks like a label and is not one: a screen reader
  announces "edit text", and tapping the label does not focus the field — the
  first thing a phone user at the counter reaches for. **404 labels in the same
  file already did this correctly**, so this was drift, not a convention.
  - 51 adjacent labels now point at their field's id
  - 5 per-branch loyalty override fields got an `${idx}`-suffixed id and a `for=`
    (they used `data-*` hooks because the row repeats)
  - 1 disabled business-name field on the invite screen
- **6 date/number pickers with no name at all** got an `aria-label`: the Staff
  performance and P&L date ranges, the Daily report date, the per-service
  commission override. Invisible, no layout change.
- **`On` was untranslated while `Off` was translated.** Ruling 4's own gap:
  five `Live` pills (zh `已启用`) became `On`, which had no entry in either
  table, so a Chinese reader saw `关闭` for off and English "On" for on. `On`,
  `Turn on`, `Turn off`, `Scheduled`, `Ended` are now in both curated tables.
  `开启`/`关闭` and `Hidup` are this repo's own attested words
  (`CUSTOMER_COPY` `soundOn`/`soundOff`); **`Hidupkan` and `Matikan` are
  inflections of those roots and are the two worth a native speaker's eye.**
- **`Resume` renders as `简历`** — the noun for a curriculum vitae — from the
  machine-generated catalogue, live on the Memberships resume button.
  Corrected to `恢复`.
- **Referrals paired "Enabled" with "Off"** in one select: half old
  vocabulary, half new, left behind by the ruling-3 pass. All three sites now
  read from `STATUS_WORDS`.

Three tests asserted the old label markup verbatim and were updated to
**require** the association rather than forbid it — `v325` already expected
`for=` on the edit path's buffer fields, so this brought the add path into line
with the assertion two lines below it.

---

## 6. Found, verified, deliberately NOT fixed

These are real. Each was chased to root cause before being left alone. **Do not
re-report them as new.**

### 10 duplicate element ids on `customer-interface`

`walletBody`, `customerNavScan`, `walletReferralSlot`,
`customerBusinessReferralDetailV362`, `customerBusinessReferralTitleV362`,
`customerBusinessRewardsDetailV347`, `customerBusinessRewardsTitle`,
`customerMemberCodeSlotV310`, `customerEarnMoreV339`,
`customerEarnMoreTitleV339`.

**Cause:** V325 pairs Step 1 and Step 2 each with a copy of
`customerInterfacePreviewSideCardHtmlV325()`, and V296 *hides* sections rather
than omitting them — so two copies of the customer wallet markup sit in the DOM
at once.

**It is latent, not live.** The 38 `$('walletBody')` lookups belong to the
customer app's render path, which does not run on this business route. Nothing
is currently dead. It is invalid HTML and a trap for whoever next wires the
preview by id — only the first copy would update.

**Why not fixed:** the fix means editing preview markup shared with the real
customer wallet. That is not a cosmetic change.

### 28 of 46 literal `.pill` words have no translation in either locale

`Ready`, `Completed`, `Used up`, `Awaiting payment`, `Awaiting confirmation`,
`Never visited`, `Not live yet`, `Not set up`, `Not available`, `Invite
pending`, `In progress`, `In history`, `Ends soon`, `Editable draft`, `Top
tier`, `Ready to claim`, `Ready to scan`, `Pending merchant scan`, `Payment
lapsed`, `Non-revenue`, `New`, `No app access`, `App access active`, `Staff
access included`, `Birthday month only`, `Available now`, `Automatic`, `Waiting
for the counter`.

Status badges are the least-translated surface in the app. The six words routed
through `STATUS_WORDS` are now translated; these are the ones still hardcoded
inline. Consolidating them is the same job ruling 4 started.

### `CACHE_VERSION` is stale — bump before deploying

`app/sw.js` still reads `v11-20260813-v298-caption-once`. The worker is
**network-first**, so online users get this branch's CSS and JS the moment it
deploys — no staleness there. But the offline shell is only re-cached when the
worker file itself changes, so an offline visitor keeps the pre-audit interface
indefinitely. **Bump that string as the last commit before deploying.**

### The customer app's translation gap is bigger than its copy table suggests

`CUSTOMER_COPY` is complete on paper — 230 keys each in zh-CN, ms and ta,
nothing missing against en. The rendered screens still measure 22–38%
translated, *worse* than most workspace screens, because a great deal of
customer-facing text never became a `ct()` key at all: the greeting, section
headings, category chips (`All`, `Beauty`, `Food & drink`), booking tabs
(`Ongoing`, `Cancelled`, `History`), `View all`, `See all`, `Book now`.

**Counting keys is not a coverage measure. Measure the rendered screen.**

Also: 5 sentence-keys on the "My Peekaa QR" screen are untranslated in all
three non-English locales.

### Workspace shell strings

Six strings appear on **all 25 business routes** — `Rewards & Offer`,
`Customer Interface`, `Build identity unavailable`, `Find a customer by name or
phone`, `Viewing`, `Customer view`. They are the nav rail and top bar, and
translating those six alone lifts every workspace screen at once. Roughly 240
more are specific to a single page.

---

## 7. False positives caught — do not re-report these

Six classes were chased down and **discarded before reaching the owner**. This
list exists so the next session does not spend the same hours.

1. **`data-*` "dead handler" scan returned 55 hits**, nearly all false because
   selectors are built from template literals that defeat static matching. The
   whole pass was discarded rather than reported.
2. **`setMs()` / `togglePlan()` flagged as undefined** — they are defined as
   `if(canWrite)window.togglePlan=`, which an anchored regex missed. All 34
   inline handlers resolve.
3. **23 "unguarded RPC null reads"** — verified against `db/migrations/`; all
   locatable SQL builds a value on every path. Latent at most, not live bugs.
4. **`booking_policy.trim()` crash** — the fixture made it an object; it is a
   `text` column per `frenly_v7_team_brand.sql`. Harness artifact.
5. **17 "controls with no accessible name" on `clients`** — the detector used
   `innerText`, which is layout-dependent and returns `''` for anything not
   currently rendered, so every collapsed nav item looked unnamed. Fixed to use
   `textContent` + `checkVisibility()` + `img[alt]` + `svg title`. All 17 were
   false.
6. **"59 `ct()` keys missing from `en`"** — the key-extraction regex only
   matched line-start keys and the copy table packs many per line. Re-run by
   actually evaluating the object: nothing missing.

And twice now, **a uniform failure across many routes has been the harness, not
the app**:

- First click run: **65 "problems", every one** `sb.rpc(...).abortSignal is not
  a function` — the double returned a bare Promise.
- First render sweep: **all 46 routes blank** — the CDN `<script>` carries an
  SRI `integrity` hash, so substituting its *body* is blocked. The fix is to
  rewrite the HTML *document* and swap the whole tag.

**Treat any uniform failure across many routes as a harness fault until proven
otherwise.**

---

## 8. Workflow facts that will cost you time

**`app/app.js` is the only editable source.** `app-business.js`,
`app-customer.js`, `app-core.js`, `app-auth.js`, `app-i18n.js` are *generated
splits*. Never edit them.

**Fixtures embed the production CSS.** Eight files under `tests/browser/` carry
a verbatim copy of the stylesheet plus a SHA-256 of the source. Two tests
compare against captured Chrome measurements. Any CSS or render-function change
makes them stale, and the failure reads like a real bug ("must come from
current production source").

```sh
npm run bundle-stamp                             # only if you edited app/app.js
node scripts/quality/regen-visual-fixtures.mjs   # then this
npm run quality && npm run bundle-stamp:check && npm test && npm run build
```

**v142 evidence always shows a diff.** Its capture mints fresh idempotency
UUIDs each run. If `git diff` on
`docs/qa/evidence/v142-connect-paynow-pos/` shows only `*_idempotency_key`
changes, `git checkout --` that directory. Its test does not assert byte
equality.

**Two fixtures were already stale before this work** —
`reward-overview-owner-visual.html` and `v181-onboarding-board.html`.
Regenerating them sweeps ~400 unrelated lines into your diff. The regen script
restores them to HEAD. Worth a separate look someday.

**Five test files execute code sliced out of `app/app.js` via `new Function`**
(`v180`, `v259`, `v271`, `v319`, `v326` under `tests/business-ui/`). Adding a
new top-level helper to `app.js` puts it out of their scope and they fail with
"X is not defined". The fix used here: have the harness slice the *real*
definition out of `app.js` (see `STATUS_PRELUDE_SRC` in `v319`/`v326`) rather
than restating values in the test, so a test can never drift from the app.

**Module labels double as i18n keys.** `WORKSPACE_COPY_V97` uses the English
string as the key, so renaming a label orphans its zh-CN / Malay translation.
There is also a second, machine-generated table —
`WORKSPACE_GENERATED_COPY_V97`, ~1472 entries per locale — and lookup is
`curated ?? generated ?? source`. **Measure coverage across both.** Two
interpolation inventories (`WORKSPACE_INTERPOLATED_UI_INVENTORY_V97`,
`..._ATTRIBUTE_INVENTORY_V97`) plus a count gate in
`tests/customer-wallet/v97-workspace-localization-acceptance.test.mjs` must be
updated together when adding a template.

**Localisation scope rules.** `localizeWorkspaceSubtreeV97` walks
`.side, .appbar, .main, [role="dialog"], [data-workspace-i18n]`. A `<td>` is
skipped *unless* the node is inside `button`, `.btn`, `.pill`, or
`[data-workspace-i18n]` — which is why the Memberships `Resume` button was
showing `简历` while the rest of the row stayed as typed.

**Click-sweep scope is route-dependent.** The business workspace excludes the
sidebar rail (the same 25 nav links on 26 routes bury real findings). The
customer app does **not** — its bottom nav is a per-screen surface with live
badges, and scoping it like the workspace tested 3 of 16 controls.

---

## 9. What blocks go-live

Everything above describes the interface **with the network removed**.

| Surface | Call sites | Status |
|---|---|---|
| `sb.rpc` | 406 | stubbed — 21 fixtured, the rest return empty |
| `sb.from` | 226 | stubbed — fixed rows, no RLS |
| `sb.auth` | 63 | stubbed — a session is always present |
| `customerRpc` | 51 | stubbed — 12 fixtured this round |
| **Total** | **746** | |

Not established by anything in this branch: sign-in and OTP, Turnstile, tenant
isolation and row-level security, the append-only credit and points ledgers,
double earn/redeem prevention, till idempotency, payments, realtime channels,
the service worker's update path against a real deploy, or a customer and a
business acting on each other's state.

**What would close it:** a QA tenant with its own credentials, and this branch
deployed to a preview URL. With those two, the same harness can drive real
sign-in, record a sale on the till and watch the points land, redeem against
the ledger, and run a customer session beside a business session. Without them,
no amount of further static work moves the needle.

Note: no credentials were ever provided to this session, `CLAUDE.md` forbids
storing them, Turnstile gates every auth screen, customer sign-in needs a phone
OTP, and the live app is production carrying real tenant data. There is also no
screen to drive — no `DISPLAY`, no Wayland or X11 socket, no VNC; only `Xvfb`
with no streaming path, and the proxy is outbound-only. Running Claude Code
locally on the owner's own machine is the real answer to interactive testing.

---

## 10. What to pick up next, in order

The first item is the only one that blocks a deploy.

1. **Bump `CACHE_VERSION` in `app/sw.js`** as the final commit before
   deploying. One line. §6.
2. **Translate the six workspace shell strings.** They appear on all 25 routes;
   this is the single highest-leverage translation change available. §6.
3. **Confirm `Hidupkan` / `Matikan`** with a native Malay speaker, and decide
   on the 28 untranslated pill words. §5, §6.
4. **`CUI.status` / `CUI.field` adoption.** Still **0** uses against 156
   hand-written pills and ~58 hand-written forms. Ruling 4 fixed the *words*;
   the *component* consolidation is open, and it is the root cause of both the
   pill drift and the label gap just fixed.
5. **KPI tiles — half done.** The load jump is fixed. Still open: three
   implementations (`.card.kpi`, `.card.kpi.v150-kpi`, `.dashboard-metric.kpi`).
   Collapsing them **needs an owner decision**, because Dashboard's tile is a
   clickable button with an arrow and action label while the others are static.
6. **Colour: 208 distinct hex → ~28.** Ruling 1 fixed the brand red. Still
   open: ~32 near-identical warm tints, five greens, and renaming the token sets
   to `--biz-*` / `--cust-*` so the split is explicit.
7. **Typography.** 108 distinct font-size values; the proposed seven-step scale
   (11 / 12.5 / 14 / 15 / 18 / 22 / 30) is not implemented.
8. **Spacing.** `--space-1…6` are defined and used **zero** times.
9. **Components.** 24 distinct `CUI.icon` sizes and 42 distinct
   border-radius values (both re-measured at head); `CUI.card` 6 uses against
   ~370 hand-written cards. The original audit also counted ~10 modal
   implementations, 4 mobile gutter conventions and 6+ tab implementations —
   those were judgement counts, not a mechanical measure, so re-derive them
   before quoting.
10. **Customer home surface.** The `-v343/344/346` series is 333 of the 400
    version-suffixed classes and holds nearly every selector declared 3+ times.
    Biggest single win — do it **last**, once the tokens above are settled.
11. **The duplicate-id fix on `customer-interface`**, if the owner wants it —
    it needs a call about touching shared preview markup. §6.

---

## 11. Ground rules that applied throughout

- `app/app.js` is the only editable source; run `npm run bundle-stamp` after
  touching it.
- Gates before every commit: `npm run quality`, `npm run bundle-stamp:check`,
  `npm test`, `npm run build`.
- Tests that locked old values were **updated, never weakened** — every
  assertion kept its intent, and the WCAG contrast gate was taught to resolve
  token aliases rather than have its thresholds relaxed.
- Verify anything a sweep surfaces against `db/migrations/`, or reproduce it in
  a browser, **before reporting it**. Six false-positive classes have already
  been caught this way (§7).
- Nothing here is deployed.
