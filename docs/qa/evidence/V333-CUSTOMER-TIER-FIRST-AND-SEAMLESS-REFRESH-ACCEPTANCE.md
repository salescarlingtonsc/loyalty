# V333 — customer view: tier first, and a refresh that does not announce itself

Date: 15 August 2026
Owner instruction (screenshot of the Cubbly programme page on an iPhone, 390px):

> 1. keep refreshing by itself — i need it to load seamlessly. must be immediate
> 2. shift the tier up — to the top of the screen (instead of points & gift) — and the UI UX is
>    being squeezed

Version note: `v319`–`v332` are already taken on `main` (V319 Rewards & Offer, V320 remove
spendable credit, V322 programme rulings, V323 stamp quest, V324×5, V326×2, V332 growth
lifecycle), so this work is numbered **v333**. No migration ships with it — every change is in
`app/app.js` and `app/index.html`.

**Redo note:** this fix was first built in the `codex/v299-customer-experience-polish` worktree,
which turned out to be 49 commits behind `origin/main` with an unmergeable `NOT APPROVED, DO NOT
MERGE` commit on top, and was then reset by another session mid-session (a shared-worktree
collision — tracked files reverted to that stale commit, the untracked evidence draft survived).
Everything below was rebuilt from scratch against current `origin/main` in an isolated worktree
(`codex/v333-customer-refresh-tier`) rather than salvaged, so line numbers, surrounding v320–v332
context (notably the v326 "paused Tier drops out entirely" rule, and v320 removing the spendable
credit metric) are all read fresh from the real current source, not carried over from the stale
diff.

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

This is a **separate** cause from the v321 pwa.js self-refresh mechanism (`86ba2c5`, already on
`main`) that a prior session removed on 2026-08-14. That fix targeted a service-worker
`location.reload()` reachable from any page, including logged-out; it was verified stable on the
logged-out customer page but the owner kept seeing refreshing on the *logged-in* wallet — which is
exactly the surface this fix touches. The two are complementary, not competing explanations.

### What it does now

`renderCustomerWallet(businessSlug, {silent})`. A silent pass does the reads and then does
**nothing at all** unless an answer changed:

- **no shell rebuild.** The page on screen is the page that stays.
- **a fact signature** (`customerWalletFactSignatureOfV333`) over the *server payloads* the
  visible cards are drawn from — not over rendered HTML. On the business page the markup carries
  loading shells the section loaders fill in afterwards, so an HTML diff would report "changed" on
  every single tick. Identical signature → the DOM is not touched.
- **a changed signature repaints in place**, holding scroll position and open `<details>`. This is
  the moment the feature exists for: the points the customer just earned.
- **`customerWalletSilentPaintV333` stands down** while a modal is open or focus is inside the
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
unaffected — it is decided by which accruing card is present, never by which is on top. The v326
rule (a paused Tier card drops out of the stack entirely, rather than showing "Programme paused")
is untouched — it still applies to whichever position the tier card is drawn in.

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

**Label budget.** Past four rungs (`TIER_RAIL_LABEL_LIMIT_V333`) the rail carries icons alone.
Nothing is lost: the current rung is named in the sentence above the bar ("You're now at Gold"),
the next rung in the sentence below it ("2 more visits to Diamond"), and every rung with its
benefits in the ladder disclosure underneath. `.customer-tier-bar.is-compact` then reclaims the
40px of vertical space that the label row used to reserve — which is the squeeze itself. A second
small rule (`.customer-tier-milestone:last-child b{transform:translateX(-50%)}`) keeps the top
rung's own label from hanging half outside the card, since its marker now sits exactly on 100%.

---

## 4 · Verification

`npm test` — 3123 pass, 4 fail. Three are pre-existing browser-evidence pins that needed a real
Chrome recapture (done, see §5) and were failing only because the fixture's inlined production
source changed; the fourth is environmental and predates this change:
`store association generator fails closed` refuses because
`node_modules/@capacitor/ios/**/PrivacyInfo.xcprivacy` is absent in this checkout (no
`npm install` of the Capacitor deps), not because of anything here.

New coverage, all of it behavioural rather than source-regex:

| suite | what it pins |
|---|---|
| `tests/customer-modules/v174-customer-tier-card.test.mjs` | the fill lands on the current rung's marker at 0% segment progress; markers are evenly spaced; a customer below rung 1 sits in the opening runway; labels drop past four rungs and the card goes compact |
| `tests/customer-wallet/v295-wallet-live-refresh.test.mjs` | the watcher re-arms itself; both surfaces refresh silently; no shell rebuild, focus move, popup or re-counted view on a silent pass; the paint holds scroll and stands down mid-interaction |
| `tests/customer-wallet/v310-programme-stack.test.mjs` | the order is tier → stamps → points → referral (v326's paused-Tier-drops-out rule kept, both order-affected assertions rewritten as order-independent `card()` extraction) |

## 5 · Regenerated browser fixtures

The CSS rules (`.customer-tier-bar.is-compact`, the label clamp, the last-marker shift) and the
changed component source are both inlined under a `production-source-sha256` pin, so every fixture
that carries the stylesheet or the `openCustomerPromotionDetailsV104 …
customerMerchantExperienceMarkupV95` span had to be regenerated with its own `generate-*.mjs`
(`npm run bundle-stamp` + all ten `tests/browser/generate-*.mjs`).

Two of them carry captured Chrome measurements keyed to that hash, so both were re-measured against
a real browser (Chrome for Testing via `playwright-core`, headless, 1440/390/412px) rather than
having their pins edited:

- `tests/browser/verify-v104-promotions-visual.mjs` → `docs/qa/evidence/v104-promotions-production-render-metrics.json`
  and the three screenshots (1440 / 390 / 412). New `production-source-sha256`:
  `ae8a3a98ed647a943b5f74045a94bac354cd68aeac0b373f71aa7afc4a92afe8`. All responsive acceptance
  thresholds still pass.
- `tests/browser/verify-v142-connect-paynow.mjs` → `docs/qa/evidence/v142-connect-paynow-pos/metrics.json`
  (desktop 1440 and 390). New `production-source-sha256`:
  `514706e9e75ba59eac2b0fee6ec0c7b4b5d66cae25ebc8790b70d502441a1630`. Still passes.

`tests/browser/reward-overview-owner-visual.html` regenerated with
`production-source-sha256`: `707468b7a31fd5c7123c4733eac3ae11ccfa3b0c88c78ad805edc4fb0af6972c` and
is wired into `tests/business-ui/v128-simple-rewards-setup.test.mjs`'s evidence chain alongside
`v319Evidence` through `v332GrowthLifecycleEvidence`.

## 6 · Bundle

`npm run bundle-stamp` regenerated `app/app-core.js`, `app/app-customer.js` and the fingerprints in
`app/index.html`, and the chunks still reassemble into `app/app.js` byte for byte.

One trap worth recording, because it cost a debugging pass once already and will recur:
`scripts/quality/app-surface-graph.mjs`'s regex-vs-division heuristic (`REGEX_ALLOWED_AFTER`)
treats a `/` after `n` as the start of a regex literal, because `n` is the last character of
`return`. A local variable ending in `n` followed directly by a division — e.g. `within/100` — is
therefore parsed as a regex, the parser loses paren depth, and **every** top-level declaration
after that point vanishes from the graph while `node --check` still passes. The rail's local is
named `segmentShare`, with a comment at the site, specifically to avoid this.

## 7 · Not changed

- No migration, no RPC, no policy. `customer_get_effective_tier_v143` is read exactly as before —
  the rail reinterprets `progress_percent` on the client, it does not ask the server for anything
  new.
- No new customer-side realtime subscription on the ledgers. The v295 reasoning stands: a customer
  holds no SELECT policy on `points_ledger` / `credit_ledger`, and widening it to feed a UI nicety
  would trade the most sensitive table in the system for an animation.
- The poll's bounds are untouched: 20s, nine ticks, paused while hidden, torn down by the router.
- The v326 paused-Tier-drops-out rule, the v320 spendable-credit removal, and every other v320–v332
  customer-wallet change are read as-is; nothing in this change re-derives or duplicates them.
