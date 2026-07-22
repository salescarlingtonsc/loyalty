# P0-RELEASE-BUILD-017 — Static deployment artifact and public routes build together

## 1. Classification

**ENGINEERING-PREP-COMPLETE.** Everything this gate's success criteria ask for already exists and
passes locally today; what remains is capturing that pass against the frozen release commit rather than
a working-tree snapshot, and a route-level smoke of the deployed artifact.

**Verified today:**
- `npm run build` (`scripts/quality/build-static.mjs`) passes: "Static build validation passed for app:
  data-request.html, index.html, join.html, privacy.html, terms.html."
- `npm run quality` (`scripts/quality/static-baseline.mjs`) passes: "Static production baseline checks
  passed."
- `npm run validate` (quality + runtime-config:check + migration-manifest:check +
  canonical-migrations:check + `npm test` + build) passes end to end, 393/393 tests, entirely offline.
- `tests/quality/inline-script-syntax.test.mjs` (part of the 393) confirms "every executable inline
  script in the SPA parses before browser boot."
- `app/privacy.html`, `app/terms.html`, `app/data-request.html` all exist and are linked from
  `legalLinks()` and the customer sign-up screen (shared finding with `P0-PDPA-OPERATIONS-007`).
- `tests/…` "Vercel security headers cover the current static app surface" and "static entry files and
  Vercel output directory exist" both pass.

## 2. Preconditions

- A frozen candidate commit SHA (shared precondition with `P0-TARGET-RUNTIME-014` and
  `P0-POST-CUTOVER-SMOKE-016`) — the artifact this gate certifies must be *that exact commit's* build
  output, not whatever is currently in the working tree, since the working tree on this branch has
  uncommitted changes (per `git status` at the top of this task).

## 3. Procedure

1. On the frozen commit only (a clean checkout, not the current dirty working tree):
   ```bash
   export EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod
   npm run validate
   ```
   Confirm the same "Static build validation passed for app: data-request.html, index.html, join.html,
   privacy.html, terms.html" line and 393/393 (or whatever the current total is at that commit).
2. Inspect the build output / Vercel output directory to confirm no unintended static artifact is
   included (e.g. a stray dev fixture, a `.env`, a source map exposing internals) and that the file list
   exactly matches the reviewed allowlist.
3. After deployment (shared step with `P0-TARGET-RUNTIME-014`), smoke every public route from its real
   entry points: the public join page, the customer portal, the auth screen, and a direct URL hit each
   resolve `/privacy.html`, `/terms.html`, `/data-request.html` without a 404.
4. Confirm the deployed artifact's security headers match what `tests/…` "Vercel security headers cover
   the current static app surface" asserts statically.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-RELEASE-BUILD-017.json`
- Example `checks`: `{"validateSuitePassed": true, "buildArtifactMatchesAllowlist": true,
  "publicRoutesResolveFromAllEntryPoints": true, "securityHeadersMatchStaticAssertion": true}`
- Include the frozen commit SHA (safe — not one of the four unsafe patterns) and test counts; no
  directory listings containing secrets, no full deployed HTML dump.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

20-30 minutes — this is the fastest gate to close given how much already passes; the only real work is
re-running it against the frozen commit instead of the working tree and doing the route smoke after
deploy.
