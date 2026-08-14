# W6 increment 2 — the four-switch programmes home (client wave)

Wave-keyed, not `vNNN`: `v315`–`v318` are held by a parallel session's prospecting work, and
`nestly_vNNN` is a shared namespace across sessions. This increment ships no migration, so it
claims no number.

Status: **REVIEWED AND ACCEPTED** — build → adversarial verification (NOT APPROVED, 5 confirmed) →
fix pass (all 5 + a 6th it found itself) → re-verification with the owed real-browser walkthrough
(NOT APPROVED, 1 regression) → containment (this review) → APPROVED. Client wave only: no migration
was written or applied and no production database was touched; the server this rides on is v313 +
v314, already live (`V313-V314-W6I1-SWITCHBOARD-INVERSION-ACCEPTANCE.md`).

## Scope shipped

`app/app.js` only, plus the two regenerated fixtures below and the test suites that slice them.
No migration was written or applied; no production database was touched.

- **A.** The setup wizard's screen 0 becomes a **switchboard**: four independent
  `role="switch"` toggles (points / tiers / stamps / referral), any subset on, applied at Go-live
  through the existing `public.set_programmes_v314` writer. The three fixed step lists become one
  rail composed from whichever programmes are on, in the customer-facing order
  STAMPS → POINTS & GIFTS → TIER → REFERRAL, with one running percentage.
- **B.** The tier rail carries the **OWNER AMENDMENT 2026-08-14** basis choice as a first-class
  visible control (visits OR points-earned, points-earned suggested for a NEW ladder only, stored
  values never downgraded, `spend` still round-tripping); the wizard produces exactly three rungs
  named Silver / Gold / Diamond (D7); and points expiry gains its own screen so every expiry mode
  the amendment protects is reachable from the wizard.
- **C.** D3's member-movement preview: threshold and basis changes are named before publish and
  gated behind their own tick. The **counts** are read from `preview_publish_impact.tier_movements`
  behind a capability check and degrade to an honest sentence — that key does not exist on the
  server yet (see the build report's SERVER ASKS).
- **D.** The W4c member QR is wired behind a capability check against
  `customer_get_member_code_v310`, which does not exist yet; the slot stays hidden until it does.

## Regenerated browser fixtures

Both inline `app/app.js` under a `production-source-sha256` pin, so both had to be regenerated with
their own `generate-*.mjs` in the same change.

| fixture | generator | production-source-sha256 |
|---|---|---|
| `tests/browser/reward-overview-owner-visual.html` | `tests/browser/generate-reward-overview-owner-visual.mjs` | `868885764aa60a0f52ac32b695966e49cd7e0a2a97021d9cf5787c381ebc4f27` |
| `tests/browser/v129-trial-test-visual.html` | `tests/browser/generate-v129-trial-test-visual.mjs` | `ed30e05f015163fa0362aafffe242447de85d92346cc3a558b86c4ff50625d34` |

This closes the residual recorded at
`docs/qa/evidence/V313-V314-W6I1-SWITCHBOARD-INVERSION-ACCEPTANCE.md` §7 — the reward-overview
fixture still inlined the pre-v314 wizard source.

**Deliberately NOT regenerated:** `v104-promotions-visual.html`, `v105-admin-visual.html`,
`v131-store-visual.html`, `v130-self-serve-visual.html`, `v141-dashboard-visual.html`,
`v142-connect-paynow-visual.html`, `v145-launch-freeze-visual.html`. They inline `app/index.html`'s
stylesheet and carry captured Chrome measurements pinned to their source hash, so any new CSS rule
would have forced a browser recapture of all of them for a cosmetic change. The switchboard is
therefore built entirely from classes the page already ships (`.grow-setup-option-v301`,
`.pill on|off`, `.imp-note`, `.muted small`) and those seven fixtures are byte-identical to their
pre-wave state.

## Test surfaces rewritten red-first

- `tests/business-ui/v301-programmes-setup-wizard.test.mjs` — the wizard suite, rewritten to the
  switchboard (17 assertions went red on the deleted symbols before being rewritten).
- `tests/business-ui/v306-wizard-mode-and-basis-hotfix.test.mjs` — 3 assertions, same reason.
- `tests/business-ui/w6i2-programmes-home.test.mjs` — new, the increment's own pins.
- `tests/business-ui/v244-ongoing-and-pending-programmes.test.mjs`,
  `tests/business-ui/v172-reward-templates.test.mjs` — one assertion each, following the
  `'Switch to this →'` → `'Turn on →'` copy change and the reward hand-off's renamed helper.

## Fix pass — adversarial verification returned NOT APPROVED (same wave, uncommitted)

An adversarial verification of the build above returned **NOT APPROVED with five confirmed-broken
defects**, every one of which passed all nineteen of the original pins. A sixth, worse than any of
them, was found by the fix pass itself. All six are fixed in this same uncommitted change, each with
a revert-to-red proof; the details, root causes and proofs live in the fix report.

| # | defect | fix |
|---|---|---|
| 1 | `growOverviewSnapshot` and both publish-gate comparisons never selected `tier_basis`, so a firm with no open draft (the state after every publish) read `undefined`, was told its ladder was NEW, and had `tier_basis='points_earned'` written over a live `visits` ladder on the first Next — the amendment's forbidden case, reaching 100% of tenants | `tier_basis` (and `stamp_target`) join all three `loyalty_programs` selects |
| 2 | D3's basis gate compared the draft against the draft, so a basis change saved in a previous session (or by the deep editor) published un-gated | a second, distinct `publishedTierBasisW6I2`, read from the published row — symmetric with the threshold half |
| 3 | the SA-4 referral double-write guard read the spine cache *after* the switch write had refreshed it, so it was false by construction: switching Referral on wrote no `referral_programs` row, switching it off (or publishing paused) left `enabled=true` and the engine kept paying | the pre-write value is captured when the wizard opens, from `referral_programs.enabled` itself |
| 4 | the Grow review and Studio publish routes collapsed a four-key spine into one legacy model key, switching a points+stamps firm's POINTS programme off and turning points ON for a referral-only firm | a publish re-asserts the spine's own four keys; only a spine with nothing on falls back to the legacy selection, so v314 increment 1's fix survives |
| 5 | a points-earned ladder with the points programme off can never move (no earn rows, metric frozen at 0), and the wizard suggested exactly that shape, forced a dead earn rate and printed copy claiming a silent accrual the engine does not have | the dependency is real and visible: the Climbing screen states it, one tap turns Points & gifts on, Visits stays a one-tap alternative, and Next/Publish refuse a stalled ladder in words. The false copy is deleted |
| 6 | **the four switches and the three expiry chips were inert in a real browser** — the handlers read `dataset.growSetupSwitchW6I2` / `…ExpiryW6I2`, and the DOM spells those attributes `…W6i2` | the correct dataset keys, with the rule written down beside them |

Two RISK items were closed in the same pass: the publish flow now re-checks `publishBlockedW6I2()`
instead of trusting a rendered `disabled` attribute (the error Retry button called `advance()`
straight past it), and the D3 tick is taken back whenever a tier row is actually written.

**Nineteen behavioural pins were added** (`W6I2 E1`–`E8` in
`tests/business-ui/w6i2-programmes-home.test.mjs`). They evaluate the wizard's real source against a
minimal DOM and assert what the owner sees and which RPC arguments leave the browser — the technique
`tests/customer-wallet/v310-programme-stack.test.mjs` already uses. Two of them build their fixture
row from the exact column list the page's own `select()` asks for, so a dropped column and the
assertion that guards it can never drift apart again.

## Re-verification — the owed browser walkthrough, and the regression it caught

A source-only review had just missed defect 6 (every toggle inert in a real browser), so the wave
was sent back for independent re-verification **with the browser walkthrough that the W6 contract
had owed since the build report's §6 risk 7**.

`tests/browser/verify-w6i2-switchboard-walkthrough.mjs` drives the REAL stamped bundles through the
real router in Chrome, with the Supabase client replaced by an in-page fixture (the
`verify-v294`/`verify-v295` pattern). **78 assertions, exit 0, at 1440 AND 390**, every one reading
rendered state (`aria-checked`, the ON/OFF pill, a `<select>`'s value, the stepper labels) or the
RPC arguments the browser actually emitted — never source text. It covers: zero switches on →
Publish refused in words; each toggle flips and leaves the other three untouched; all four on →
the rail composes in customer order with one running percentage; a points-earned basis with Points
& gifts off shows the requirement, the one-tap fix works and keeps the owner on Climbing, and
Next/Publish refuse until it is satisfied; the three expiry chips set the mode; a stored VISITS
ladder opens on Visits and a raised threshold renders the movement block with its tick, with the
count line honest rather than an invented zero; a transient publish failure whose Retry is refused
by the flow-level gate writes nothing; and exactly ONE `set_programmes_v314` call leaves the browser
per publish, after `publish_loyalty_config`, matching the switchboard exactly — all four false under
keep-it-paused, with `referral_programs.enabled` driven to match.

Run it with:

```
PLAYWRIGHT_MODULE=<path>/playwright-core/index.js \
PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
node tests/browser/verify-w6i2-switchboard-walkthrough.mjs
```

**The regression it caught (CONFIRMED-BROKEN, fixed in this review).** Fix 4 widened the legacy
publish routes to re-assert all FOUR spine keys — which made them the first non-wizard writer of
the `referral` spine row, while neither route writes `referral_programs.enabled`. That is the
column `app.on_sale_recorded` gates the referral payout on, and only the setup wizard writes it
(defect 3's fix). So a firm with referrals running that published a PAUSED draft from the Grow
review page would have read referral OFF on every surface while the engine kept minting referral
credit — defect 3's split, reopened one door over.

Containment, in the bytes: `PROGRAMME_PUBLISH_KINDS_W6I2` (`app/app.js:759-768`) is the three kinds
a legacy route may honestly govern, and `programmeSwitchesForPublishV314` (`app/app.js:839-846`)
writes that set. The "is anything running?" guard still asks all FOUR kinds, so a referral-only
firm still never falls through to the legacy tail that would hand it a points programme, and its
referral row is still left exactly as found. The wizard route is unchanged and still sends all four,
because it is the one door that writes both halves. Pinned by
`W6I2 E4 a legacy publish route never moves the REFERRAL switch (defect 4 containment)`; red-first
proof: restoring the four-key identity write turns **four** E4 tests red (36/40), restored
byte-exact (`app/app.js` sha `047b445acd1d9c50…` before and after).

**One vacuous pin replaced.** Re-verification proved the three `W6I2 E3` referral pins stayed green
if the captured "before" was read from the SPINE again, because in each of those fixtures the spine
and `referral_programs.enabled` agree. They can disagree — the spine is the display truth, that
column is the money truth. The new pin
`W6I2 E3 the referral "before" is read from referral_programs, not from the spine` uses a fixture
where the spine says referral is OFF while the live row still says `enabled=true` and the engine is
still paying; reading the spine writes nothing and leaves the payout running, reading the column
heals it. Red-first: the spine read turns exactly that test red (39/40), restored byte-exact.

## Verification summary

| surface | result |
|---|---|
| `tests/business-ui/w6i2-programmes-home.test.mjs` | **40/40** (19 behavioural pins from the fix pass + 2 from this review) |
| `v301-programmes-setup-wizard` · `v314-programme-switchboard` · `v306-wizard-mode-and-basis-hotfix` · `ps0-writer-registry` · `v21-security-hardening` | **75/75** — v314 increment 1's suite held at 11/11 throughout |
| `tests/browser/verify-w6i2-switchboard-walkthrough.mjs` (real Chrome, 1440 + 390) | **78 assertions, exit 0** |
| `npm run bundle-stamp:check` · `npm run quality` | current / passed |
| `npm test` | **2941 tests, 2940 pass**, 1 fail = the known environmental `v131` store-readiness check (this worktree has no `node_modules`, so the Capacitor privacy-manifest generator refuses) |
| red-first | 11 reverts in the fix pass + 2 in this review, each naming a failing test and restored byte-exact |
| dataset sweep | 406 `dataset.X` reads vs emitted `data-*` across `app.js` and all four bundles — 0 unmatched |

## Deferred RISK C closed — the tier ladder is a three-state read, and it fails closed

Client-only, no migration, no dependency; shipped alone because it is the destructive one.

**The defect as designed.** `app/app.js` read `loyalty_tiers` as `r.error?null:(r.data||[])` and every
consumer then wrote `Array.isArray(x)?x:[]`, collapsing "the read failed" into "this firm has no
rungs". Those demand opposite behaviour: `prefillTiersW6I2()` fires on `state.tiers.length===0`,
pushes three fresh-uuid rungs and marks them dirty, and the Tiers step's own Next writes them into a
draft `create_loyalty_config_draft` has already filled with the firm's real rungs; and
`tierMovementRiskW6I2()` required `publishedTiersW6I2().length>0`, so the D3 downgrade warning and
its tick vanished for exactly the firms whose ladder could not be read.

**The finding the contract did not contain, verified against production `gadpooereceldfpfxsod`
2026-08-14.** The read was not merely fallible — it was failing for every tenant on every load. The
V303 select asked `public.loyalty_tiers` for `active`, a column that table does not have:

```
information_schema.columns / public.loyalty_tiers
  id · business_id · name · threshold · points_multiplier · perk_note · sort · effective_from · expires_at
```

`active` belongs to `loyalty_tier_versions`; `public.publish_loyalty_config` (`prosrc` md5
`6bcc491a86d0f19a7284dc6deda83097`, untouched by this change) deletes the projection and re-inserts
those columns `where config_version_id=p_version and business_id=… and active`, so every published
rung is active by construction. PostgREST answers an unknown column with `42703`.

**It had already fired.** Cubbly (`8492e8d6-8888-4383-ada0-7e1ed69f0caa`, `tier_basis='visits'`) grew
its ladder across three consecutive owner sessions while the Tiers step showed an empty one:

| config version | rungs | ladder |
|---|---|---|
| `2128c300…` 2026-08-13 07:40 | 3 | Essential@0 · Gold@20 · Diamond@100 |
| `fd5f6901…` 2026-08-13 14:57 | 6 | + a second Essential@0, a second Gold@20, Diamond@30 |
| `6960c6ed…` 2026-08-14 03:50 | 9 | + Bronze@0, Silver@10, Gold@25 |

In `fd5f6901…` the first three rows share one `created_at` (the draft copy of the real ladder) and
the next three arrive 17s, 27s and 40s later — added on top of a ladder the screen was not showing.
The published projection now holds nine rungs, three of them colliding at thresholds 0 and 20.

**The fix, both halves.** `LOYALTY_TIER_COLUMNS_W6I2` is the published table's own column list, so
the read succeeds; and `readLoyaltyTiersW6I2()` returns `{state:'unknown'|'empty'|'rows', rows}`,
normalised once per consumer through `tiersEnvelopeW6I2()`, which treats anything unrecognised —
including `null` and an omitted argument — as `unknown`. Rule, stated in the source: an unreadable
ladder never permits a write to the ladder and never suppresses a warning.

| consumer | `unknown` | `empty` | `rows` |
|---|---|---|---|
| Programmes-page tier card | "Your tiers could not be read" + **Try again**; the Edit/Set-up tiers action is withheld | "No tiers yet" | the ladder |
| `prefillTiersW6I2()` | refuses | prefills 3 (D7 unchanged) | skips (no retroactive enforcement) |
| Tiers step body | no list, no ready-made chip, no add form; honest panel + **Try again** that re-reads | as before | as before |
| Tiers step `Next` | refuses: *"We could not read your current tiers. Reload before editing the ladder."* | proceeds | proceeds |
| `tierMovementRiskW6I2()` / the block | AT RISK — *"The published ladder could not be read, so we cannot say who moves."*, tick required | no gate | computed |
| `state.tiers` seed | the draft's ladder alone | as before | as before |

**Verification.** `tests/business-ui/w6-risk-c-tier-read-envelope.test.mjs` — 17 behavioural tests
that run the real wizard source against a `sb` stub which answers `loyalty_tiers` the way PostgREST
does, returning `42703` for any column the published table lacks, so re-adding a version-only column
to the select turns the suite red instead of production. Red-first: 10 mutants, each reverting one
half of the fix, each turning at least one **named** test red, `app/app.js` restored byte-exact
(sha256 `d292fd7203f5af69624ba8c2c441c640493ace50516ef91669f862396614e715`) after every cycle.

Three shipped source pins were pinning the defect and were replaced, each with the reason recorded
inline: `W6I2 C1` and `W6I2 (g)` required the `Array.isArray(liveTiers)?liveTiers:[]` collapse, and
`V303 (c)` required both that collapse's sibling and `active` in the select.

| fixture | production-source-sha256 (regenerated for this change) |
|---|---|
| `tests/browser/reward-overview-owner-visual.html` | `7b480dbd9e377a47ce2dd712627fa8f3272521fe1919538300e99aa6ae61867c` |
| `tests/browser/v129-trial-test-visual.html` | `9f12f5eb7576b07187bde0e98b7eea7732d5d63a73cef57d6cd8f73322a3034c` |

## Standing invariants for the next increment

1. `public.set_programmes_v314` remains the ONE writer of the spine. The wizard sends all four
   kinds; a route that cannot also write `referral_programs.enabled` must send only
   `PROGRAMME_PUBLISH_KINDS_W6I2` (points, tiers, stamps) — see the containment above. When SA-4
   moves the referral gate onto the spine, that split collapses and the constant goes.
2. Pin behaviour, never source text. Nineteen source-regex pins were green through five confirmed
   defects and an entirely inert switchboard. Build fixture rows from the exact column list the
   page's own `select()` names.
3. A points-earned ladder requires the points programme to be running; there is no silent accrual
   to fall back on (`public.business_programmes` carries `kind` and `active` and nothing else).
   Any increment that wants true silent accrual must add the column and the engine support first.
4. The OWNER AMENDMENT 2026-08-14 holds and is mechanically pinned: visits stays a first-class
   one-tap basis, points-earned is a suggestion for a NEW ladder only, stored values round-trip,
   and every points-expiry mode (fixed days including 365, inactivity, never) is reachable from the
   wizard.
5. Open server asks, none blocking: `preview_publish_impact.tier_movements` for the D3 count
   (SA-1, degrades to an honest sentence today), W4c's two member-code RPCs (SA-2, the QR ships
   switched off behind `MEMBER_CODE_CONTRACT_W6I2` because the writer-registry and v21 grant guards
   correctly refuse a bundle naming an ungranted function), per-programme gift authoring (SA-3),
   and the referral gate's move onto the spine (SA-4).
