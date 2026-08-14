# V319 — customer view: tier first, and a refresh that does not announce itself

Date: 14 August 2026
Owner instruction (screenshot of the Cubbly programme page on an iPhone, 390px):

> 1. keep refreshing by itself — i need it to load seamlessly. must be immediate
> 2. shift the tier up — to the top of the screen (instead of points & gift) — and the UI UX is
>    being squeezed

Version note: `v315`–`v318` were already taken by the migrations in this branch
(`20260814_nestly_v315_repair_dropped_lead_score_references.sql` … `_v318_align_system_managed_
stage_flags.sql`), so this work is numbered **v319**. No migration ships with it — every change is
in `app/app.js` and `app/index.html`.

---

## 1 · "keep refreshing by itself"

### What was happening

v295 added a live wallet refresh for the counter moment — a balance earned while the customer is
holding the phone should appear without them hunting for it. The fact was right; the method was
not. Its refresh callback was `renderCustomerWallet()`, whose first act is:

```js
renderCustomerShell({…, body:`<div class="card"><p class="muted">Loading Peekaa…</p></div>`});
```

`renderCustomerShell` assigns `root.innerHTML`. So every tick — every 20 seconds, up to nine
times, plus once on every return to the foreground — the entire page was torn down to a "Loading
Peekaa…" card and rebuilt. Visible consequences, all of them in the owner's screenshot:

| symptom | cause |
|---|---|
| the page "refreshes by itself" | full `root.innerHTML` rebuild on a timer |
| scroll jumps back to the top | the scrolled element no longer exists |
| the History disclosure snaps shut | `<details open>` state is not carried across a rebuild |
| already-loaded wallet sections flash back to skeletons | `walletSectionShell()` placeholders are re-emitted and re-hydrated |
| focus is thrown to `<main>` | `focusCustomerRoute()` runs on every render |
| `surface_viewed` / `programme_viewed` / DAU inflate | a poll counted as a view, every 20s, for a phone lying on a counter |

### What it does now

`renderCustomerWallet(businessSlug, {silent})`. A silent pass does the reads and then does
**nothing at all** unless an answer changed:

- **no shell rebuild.** The page on screen is the page that stays.
- **a fact signature** (`customerWalletFactSignatureOfV319`) over the *server payloads* the visible
  cards are drawn from — not over rendered HTML. On the business page the markup carries loading
  shells the section loaders fill in afterwards, so an HTML diff would report "changed" on every
  single tick. Identical signature → the DOM is not touched.
- **a changed signature repaints in place**, holding scroll position and open `<details>`. This is
  the moment the feature exists for: the points the customer just earned.
- **`customerWalletSilentPaintV319` stands down** while a modal is open or focus is inside the
  wallet body — a background repaint must never yank the DOM out from under someone mid-tap. The
  signature is committed only *after* a paint lands, so a deferred update is not lost.
- **no focus move, no promotion popup, no re-counted analytics.**
- **no error card.** Every failure branch on a silent pass keeps the working page:
  `loadCustomerSurfaceContext(isCurrent,{silent})` returns null instead of rendering a retry
  surface, and the three `renderCustomerNotJoinedV289` / `renderCustomerWalletRetry` branches
  become `silent?undefined:…`. One flaky 20-second read can no longer replace a customer's wallet
  with an error.

"Immediate" is the other half: the foreground listener still reads the instant the app comes back.
It just no longer announces itself by blanking the screen first.

### One structural change the above forced

`watchCustomerWalletV295` used to be re-armed only by the full re-render its own tick triggered.
With the rebuild gone there is nothing to re-arm it, so the watcher now **re-arms itself**
(`await refresh(); arm()`), and a silent pass rides the *current* render epoch rather than opening
a new one — bumping it would make the watcher that scheduled the refresh look stale to itself and
stop. The epoch guard still works: a real navigation renders non-silently, bumps the epoch, and
every `await` in the abandoned pass sees it.

---

## 2 · "shift the tier up"

`PROGRAMME_STACK_ORDER_V310` is now `['tiers','stamps','points','referral']`, and
`customerProgrammeStackV310` paints in that order. Tier is the standing that names the customer at
this business and the one fact that does not change when they spend, so it is what the page opens
with.

This is the stack catching up to the surface it replaced rather than a second opinion: the v194 tab
fallback (`customerProgrammeSummaryTabsV194`) has always opened on the Tier tab. The gifts host is
unaffected — it is decided by which accruing card is present, never by which is on top.

---

## 3 · "the UI UX is being squeezed"

The tier rail had two defects, visible together in the owner's screenshot (nine tiers: four icons
stacked on the left of the track with `Essentia`/`Silver`/`Gold`/`Diamond` printed over one
another, a lone `Diamond` at the right, and a fill ending at ~57% that agreed with no marker).

**(1) The fill and the markers were on different scales.** Markers were placed at
`threshold / topThreshold`; the fill was drawn at `tier.progress_percent`. But `progress_percent`
is not a position on that scale — the server computes it as

```sql
(v_metric - coalesce(v_current.threshold,0)) * 100
  / nullif(v_next.threshold - coalesce(v_current.threshold,0), 0)
```
(`20260813_nestly_v310_programme_read_path.sql:690-693`)

— progress *through the current segment*, which resets to 0 every time a rung is reached. A Gold
customer 57% of the way to Diamond drew a fill at 57% while the Gold marker sat at 34%.

**(2) Crowding.** Thresholds on a real ladder are near-exponential, so on the threshold scale the
lower rungs pile onto the left of the track.

Both are fixed by putting the whole rail on one language — the **rung index**:

- marker *i* sits at `(i+1)/count`, so every rung gets the same room whatever numbers the firm set,
  and the top rung still lands exactly on 100%;
- the fill is `(currentIndex + 1 + progress_percent/100) / count`, so at 0% through a segment the
  fill ends *on* that rung's marker;
- `(i+1)/count` rather than `i/(count-1)` because 0% is "no tier yet" — a real state (metric below
  the first threshold, `v_current` null, the server measuring progress from 0) that needs somewhere
  on the track to live.

**Label budget.** Past four rungs (`TIER_RAIL_LABEL_LIMIT_V319`) the rail carries icons alone.
Nothing is lost: the current rung is named in the sentence above the bar ("You're now at Gold"),
the next rung in the sentence below it ("2 more visits to Diamond"), and every rung with its
benefits in the ladder disclosure underneath. `.customer-tier-bar.is-compact` then reclaims the
40px of vertical space that the label row used to reserve — which is the squeeze itself.

---

## 4 · Verification

`npm test` — 2946 pass, 1 fail. The one failure is environmental and predates this change:
`store association generator fails closed` refuses because
`node_modules/@capacitor/ios/**/PrivacyInfo.xcprivacy` is absent in this checkout (no
`npm install` of the Capacitor deps), not because of anything here.

New coverage, all of it behavioural rather than source-regex:

| suite | what it pins |
|---|---|
| `tests/customer-modules/v174-customer-tier-card.test.mjs` | the fill lands on the current rung's marker at 0% segment progress; markers are evenly spaced; a customer below rung 1 sits in the opening runway; labels drop past four rungs and the card goes compact |
| `tests/customer-wallet/v295-wallet-live-refresh.test.mjs` | the watcher re-arms itself; both surfaces refresh silently; no shell rebuild, focus move, popup or re-counted view on a silent pass; the paint holds scroll and stands down mid-interaction |
| `tests/customer-wallet/v310-programme-stack.test.mjs` | the order is tier → stamps → points → referral, and per-card assertions are now extracted by card kind so they no longer depend on stack order |

`tests/browser/verify-v310-customer-stack-walkthrough.mjs` — **ALL STEPS PASSED**, driving the real
stamped bundles through the real router in Chrome at 390px. Step a now reads
`tiers → stamps → points`, referral still stack position 4, four programmes still fit in about one
and a half thumb-scrolls (1.21 screens).

Step d — the v310 rollback proof — needed one scoped change and it is worth stating plainly. It
asserts the v194 fallback DOM is byte-identical to the pre-change bundle. The v319 rail fix is
deliberately on **both** paths, so the geometry numbers now differ by design and pinning them
byte-for-byte would be pinning the bug. The comparison therefore blanks *only* the two geometry
values (the bar's `width`, each marker's `left`) and asserts byte identity across all remaining
6457 bytes — every element, class, attribute, sentence and rung label — with a guard that the
normalisation actually removed something, so it cannot degrade into comparing two blanked strings.
The geometry itself is asserted on its own terms in `v174-customer-tier-card.test.mjs`.

Screenshots: `docs/qa/evidence/v310-customer-stack-390.png` (tier card first; three evenly spaced
rungs; the fill ends between Explorer and Pioneer at 56.67%, which is Explorer's own marker plus
70% of that segment, matching "3 more visits to Pioneer"), plus the four-programme, dark and 1440
captures beside it.

## 5 · Regenerated browser fixtures

The CSS rule (`.customer-tier-bar.is-compact`, plus the label clamp) and the changed component
source are both inlined under a `production-source-sha256` pin, so every fixture that carries the
stylesheet or the `openCustomerPromotionDetailsV104 … customerMerchantExperienceMarkupV95` span had
to be regenerated with its own `generate-*.mjs`.

| fixture | production-source-sha256 |
|---|---|
| `tests/browser/reward-overview-owner-visual.html` | `f10bb624afa329ba2081c91df32b3a41b8ab98408d61d358fc47d03439e2edff` |
| `tests/browser/v104-promotions-visual.html` | `0ab8203c41d1eb9182027463495576cb94061474c8809b87e4bab1ae29e45d87` |
| `tests/browser/v129-trial-test-visual.html` | `62f21009cb3624639d28224fd0a99f4eb028af6fe59502c25f94e087ea52476a` |
| `tests/browser/v130-self-serve-visual.html` | `419da2b98bd930439582cabf32abe1345c30016b2164d81310dfd3f176426e91` |
| `tests/browser/v131-store-visual.html` | `ccd8d6cc74ff1e3b388aa3e02184faed2bc2acb7d6ea3f254a6deae0f275cc09` |
| `tests/browser/v141-dashboard-visual.html` | `d902dfdc15150d1b8716294498913d7503b43e9aa8c2057d57b9e913b6df2a88` |
| `tests/browser/v142-connect-paynow-visual.html` | `853276ebfd0aa01af27ae6c021aeaac8d4006b69b54e9677f206c1ae987cca49` |
| `tests/browser/v145-launch-freeze-visual.html` | `a5e25bb92cc7685798cc857f31495b662a3d137660dca092e945b5229a5cdb2e` |
| `tests/browser/v105-admin-visual.html` | (v105 component sha, regenerated) |

Two of them carry captured Chrome measurements keyed to that hash, so both were re-measured against
a real browser rather than having their pins edited:

- `tests/browser/verify-v104-promotions-visual.mjs` → `docs/qa/evidence/v104-promotions-production-render-metrics.json`
  and the three screenshots (1440 / 390 / 412). All responsive acceptance thresholds still pass.
- `tests/browser/verify-v142-connect-paynow.mjs` → `docs/qa/evidence/v142-connect-paynow-pos/metrics.json`
  (desktop 1440 and 390). Still passes.

## 6 · Bundle

`npm run bundle-stamp` regenerated `app/app-core.js`, `app/app-customer.js` and the
fingerprints in `app/index.html` (core 342KB · auth 23KB · customer 412KB · business 1793KB ·
i18n 208KB), and the chunks still reassemble into `app/app.js` byte for byte.

One trap worth recording, because it cost a debugging pass and will recur: the splitter's
regex-vs-division heuristic (`scripts/quality/app-surface-graph.mjs`, `REGEX_ALLOWED_AFTER`) treats
a `/` after `n` as the start of a regex literal, because `n` is the last character of `return`. A
local named `within` therefore made `within/100` swallow the rest of the line as a regex, the
parser lost paren depth, and **every** top-level declaration in a 34 000-line file vanished from
the graph. `node --check` passes throughout. The variable is now `segmentShare`, with a comment at
the site.

## 7 · Not changed

- No migration, no RPC, no policy. `customer_get_effective_tier_v143` is read exactly as before —
  the rail reinterprets `progress_percent` on the client, it does not ask the server for anything
  new.
- No new customer-side realtime subscription on the ledgers. The v295 reasoning stands: a customer
  holds no SELECT policy on `points_ledger` / `credit_ledger`, and widening it to feed a UI nicety
  would trade the most sensitive table in the system for an animation.
- The poll's bounds are untouched: 20s, nine ticks, paused while hidden, torn down by the router.
