# V306 — W0 programme hotfixes: stamps unblock, tier-basis truth, 'both' shows the ladder

First build wave of the four-independent-programmes plan
(`docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md`, owner approval 2026-08-13
"proceed with all recommendations", ledger `PROGRAMME-INDEPENDENCE-001`). Three live
bugs found by the plan's code audit, fixed before any architectural work so the wizard
stops damaging tenants that exercise the new rulings.

## The three bugs

1. **Switching to Stamp card left a stale `points_mode` that blocked every stamp
   redemption.** `targetPointsModeV303` returned `null` for the stamps pick and
   `applyPointsModeV303` treats a falsy target as "no change" — so a firm that ran
   Tiered membership kept `points_mode='tiers'`, whose v229 server gate refuses ALL
   redemption and whose `rewards` capability is false. Fix: the stamps pick now targets
   `'redeem'` (the v229 backfill value): it passes the redemption gate and keeps
   `coalesce(points_mode,'tiers')='tiers'` false so an ex-tiers firm's leftover ladder
   never resurfaces on the customer page (NULL would have resurrected it). The Go-live
   step states the switch in the owner's words (new stamps mode line).
2. **The wizard wrote an illegal `tier_basis` and silently downgraded ladders.** The DB
   CHECK is `visits|spend|points_earned`; the wizard radio speaks `visits|points`. The
   UI key `'points'` was written raw (CHECK violation — saves failed), and reading back
   `'points_earned'` or `'spend'` collapsed both to `'visits'` (silent downgrade; one
   open production draft with `points_earned` was exposed). Fix: boundary translators
   `tierBasisFromDbV306` / `tierBasisToDbV306` at the exactly-two read and exactly-two
   write sites; `'spend'` round-trips untouched (no radio offers it; only an actual
   click moves a firm off it).
3. **`points_mode='both'` never showed the tier ladder to customers.** v239 made 'both'
   legal; v231's `customer_portal_capabilities` still decided the `tiers` capability
   with `coalesce(v_points_mode,'tiers') = 'tiers'` — false for 'both'. Migration
   `nestly_v306_both_mode_shows_tiers` (slot 20260813000200) text-patches the APPLIED
   definition (v229/v121 precedent) to `in ('tiers','both')` with pre/post assertions:
   anchor exactly once, security/payload contracts intact, exact-replacement idempotence
   probe (probing the full new predicate, never a loose substring), post-count new=1
   old=0. No grants (create-or-replace preserves the v231 ACL). The `rewards` capability
   and the v229 redemption gate were verified already-correct for 'both' and are
   untouched; the client two-tab tier+points layout mounts unchanged the moment the
   server answers `tiers=true`.

## Production pre-state (audited before build, 2026-08-13)

No tenant currently damaged: zero stamps firms on `points_mode='tiers'` (the one stamps
firm is on 'redeem'), zero firms on 'both', all 10 live programmes on visits-basis.
One open draft carries `tier_basis='points_earned'` — bug 2 would have destroyed it on
the owner's next wizard entry; the fix preserves it. No data repair required; all three
fixes are protective. The live `customer_portal_capabilities` definition was confirmed
byte-identical to v231's file (anchor occurs exactly once; 'both' absent), and a sweep
of every `public`/`app` function proved only two behavioural `points_mode` readers
exist (capabilities + the v229 gate) — the other four (`customer_explore_businesses_v244`,
`customer_get_effective_tier_v143`, `customer_get_reward_catalog`,
`customer_list_business_directory_v242`) pass the value through as payload only.

## Verification

- **Red-first**: 12 load-bearing source patterns RED at HEAD (main@4a4fa41), GREEN
  after; the updated pins in `tests/business-ui/v301-programmes-setup-wizard.test.mjs`
  fail against HEAD's app.js (independently reproduced: 6/7 red in a scratchpad tree).
- **New regression suite**: `tests/business-ui/v306-wizard-mode-and-basis-hotfix.test.mjs`
  (6 tests) — stamps→'redeem' with the `?null:` form absent file-wide; both translators
  verbatim; every read via fromDb and every write via toDb with the raw patterns absent
  file-wide and a comment-stripped count proving exactly 2 tier_basis writes; the radio
  still offers exactly visits+points.
- **Walkthrough**: `tests/browser/verify-v301-setup-wizard-walkthrough.mjs` gains step
  (p), four sub-steps against the stamped production bundles: p1 tiers-firm→Stamp
  card→publish ends with exactly ONE `businesses` update, carrying `points_mode='redeem'`,
  sequenced AFTER `publish_loyalty_config`, and the stamp-specific Go-live sentence
  rendered; p2 a `points_earned` draft shows the "Points earned" radio selected (the
  downgrade is gone); p3/p4 both draft write sites carry `'points_earned'` — plus a
  sweep asserting no draft write of the run ever carried a value outside the CHECK.
- **Adversarial verification**: two independent reviewers over the two build diffs.
  Confirmed complete/minimal; four hand-traced behaviour paths hold (tiers→stamps,
  untouched round-trip, spend firm no-write, new firm legal values); migration anchor
  byte-verified against v231 line 113; registration recomputed (manifests regenerated,
  shas match, `--check` clean); db-test fixture schema-checked column-by-column. Their
  two substantive findings were folded in before ship: the idempotence probe now probes
  the exact replacement text (a loose `'both'` substring probe would fail OPEN), and
  the db test's step-7 needle pins the full predicate.
- **Rolled-back production rehearsal**: `db/tests/v306_both_mode_capabilities.sql` —
  see the Production apply section below for the red-first pre-apply run and the green
  post-apply run.
- **Suite**: `npm run validate` green except the pre-existing environment-bound
  `tests/mobile/v131-store-publication-readiness.test.mjs` sub-test (Apple/Android
  signing env; fails identically on pristine main on this machine).

## Production apply (2026-08-13, project gadpooereceldfpfxsod)

- **Red-first pre-apply** run of the suite against production: step 1 FAIL
  (`tiers=false` under 'both' — the bug, reproduced live), step 7 FAIL (unpatched
  shape), steps 2–6 PASS (existing behaviour and the v229 gate intact; step 6 reached
  "insufficient points", proving the mode gate passes under 'both').
- **Combined rolled-back rehearsal** (migration DO block + full suite in one
  transaction, rolled back): 7/7 PASS.
- **Applied** as `nestly_v306_both_mode_shows_tiers` via the migration API.
- **Post-apply live suite**: 7/7 PASS (rolled back; fixture left nothing behind).
- **ACL floor**: `anon` execute **false**, `authenticated` execute **true**, exactly
  one overload — the v231 ACL survived the create-or-replace as designed.
- **Advisors (security)**: 0 ERROR (235 INFO / 612 WARN platform-wide); the only
  mention of `customer_portal_capabilities` is the pre-existing standard
  authenticated-SECURITY-DEFINER WARN, unchanged.

## Production deploy verification (2026-08-13, post-push)

`https://www.peekaa.asia/api/build` reports `commitSha
3c7d548d120d5e57f50c776c7d439d9fe9888b44` (this change); the live shell at `/app`
references `app-business.js?b=6a4ee6a9f7c9` and the served chunk's sha256 equals the
local stamped file byte-for-byte (`6a4ee6a9f7c9e26f…`), carrying the stamps→'redeem'
mapping. Anon REST probe on `customer_portal_capabilities` returns the identical
anon-blind profile (401) as the known-good baseline `customer_get_business_summary`.

## Regenerated fixture identity

reward-overview-owner-visual.html production-source-sha256 (regenerated for the V306
wizard source; supersedes the V300 hash for current-tree byte identity):

    8de22c3c2e53872b17a22795a52598e0ff5062f9d210e185dd7f7a06f9d4c941

v129-trial-test-visual.html regenerated for the same reason (byte-equality restored).

## Residuals (recorded, deliberately out of W0 scope)

- A future `'spend'`-basis firm entering the wizard sees four visits/points-worded
  labels (`tierUnitLabelV303`, `tierRowThresholdTextV304`, the tier validation message,
  the Climbing else-branch) and a radio group with nothing selected. Zero production
  firms are on 'spend'; W6 retires the basis choice entirely per approved decision D1.
- The comment at the tiers-step basis save ("Tiers-only never reaches this line") is
  stale — a tiers-only owner who changes the basis on Climbing performs a second,
  redundant same-value save; harmless and now always legal. Cleaned up with W6's wizard
  rework rather than churning the pinned source twice.
- Whole-run draft-write sweep in walkthrough step (p) covers writes since the last
  in-test reseed (page.reload re-creates the recorder), slightly narrower than its
  comment claims.
