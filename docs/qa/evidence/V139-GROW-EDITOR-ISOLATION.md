# V139 Grow editor isolation evidence

Date: 2026-08-02

Branch: `codex/v139-grow-editor-isolation`

Lifecycle: production deployed and verified for the reported editor-isolation defect
Production-component source SHA-256: `b80039cbe1b6f77fd928c0e2d46577282fdd861a9c8bf87d7e022afca9745d7a`

## Reproduction

The owner's live screenshot from production build `c22eb2189f4b` shows the
Birthday benefit editor mounted below the Earn/points editor. The V138 browser
acceptance proved focus routing but did not assert that sibling forms and the
overview were absent.

## Candidate behavior

- Earn, classic redemption, one stable reward UUID, Add reward and Birthday
  carry one explicit editor intent.
- Opening an editor hides the Grow overview instead of appending the editor
  below it.
- The Loyalty renderer removes every sibling editor before interaction.
- Exact reward and Add remove the catalogue rows after opening the requested
  form.
- Save/Done returns to `#/grow`; direct routes and refresh preserve the exact
  editor intent.
- The customer projection is unchanged. No candidate action publishes.

## Evidence

- Red-first/static regression:
  `tests/business-ui/v139-grow-editor-isolation.test.mjs` — 5/5 pass.
- Prior V138 closure regression:
  `tests/business-ui/v138-auth-grow-closure.test.mjs` — 11/11 pass.
- Source-bound Chromium:
  `tests/browser/verify-reward-overview-owner.mjs` — PASS at source hash above.
  It verifies exact reward, Earn, Birthday and Add isolation, stable-ID refresh,
  hidden overview, 1440px and 390px no-overflow behavior, plus the prior
  owner/read-only/limited-module/retry suite.
- Visual artifacts:
  `docs/qa/evidence/reward-overview-owner-browser/owner-exact-reward-editor-desktop-1440.png`
  and `owner-exact-reward-editor-mobile-390.png`.
- Static production baseline and build pass with
  `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod`: full repository
  validation passes 1,434/1,434 with zero failures, followed by a successful
  static build.
- Independent Sol review: **ACCEPT**, P0/P1/P2 all zero, for source hash above
  and frozen uncommitted diff SHA-256
  `4325699bbd4f39c008d6dadc436e75157f6eef7fda6e567100e07be1b7ce07a8`.

## Production release

- Owner release approval: 2026-08-02, scoped to V139 commit/push, reviewed V138
  production migration and web production deployment.
- Commit: `8422ed2` on `codex/v139-grow-editor-isolation`, pushed to origin.
- Vercel production deployment: `dpl_9YfeQfJ7tkqLAyEs81iL54oE5mWz`, READY,
  aliased to `https://www.peekaa.asia`.
- The bare host returns HTTP 308 to the canonical `www` host. The served
  canonical HTML contains both V139 intent and isolation hooks.
- Production migration history already contained
  `20260802081212_nestly_v138_auth_grow_closure`; the release therefore did not
  replay duplicate DDL. Read-only registry verification found all six expected
  V138 RPCs with the reviewed anonymous/authenticated grants.
- Authenticated live Chrome verification on Cubbly at
  `#/loyalty/b56a7117-a90b-45c9-8e8d-b753a3baae8e/earning` found editor intent
  `earning`, one programme editor, zero reward editors, zero Birthday editors,
  zero redemption editors and no horizontal overflow. Returning to `#/grow`
  showed enabled rows for Earn, Free tofu, Birthday, Add reward and Bring-back.
  No production programme or customer record was mutated during verification.
- Vercel reported no deployment errors in the post-release log window.

## Remaining boundary

The exact owner-reported defect—Points/Earn also showing Birthday—is verified
resolved in production. Separate programme writes, visibility changes and
customer projections remain governed by their own ledger rows and must not be
called production-proven merely from this non-mutating release check.
