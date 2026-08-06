# Peekaa repository instructions

These instructions apply to every task in this repository and take precedence
over conflicting legacy workflow guidance in `CLAUDE.md`, product documents, or
older release notes. A newer explicit owner instruction takes precedence over
this file.

## Default workflow: ship normal work

This repository prioritises shipping velocity. For normal feature work, the
definition of done is:

1. Implement the smallest correct version of the requested feature or fix.
2. Run only targeted verification relevant to the changed behaviour.
3. Fix any issue found by that verification.
4. Commit the completed changes.
5. Push the commit to the repository.
6. If the task is intended for production, deploy it to the live environment.
7. Report the commit hash, branch, deployment URL or version, and a brief
   summary of the changes.

Normal work is not complete until it has been committed and pushed, and—when
production deployment was requested—deployed successfully.

Do not pause normal work to request an independent Sol review, an `ACCEPTED`
status, a `RELEASE APPROVED` phrase, extra governance approval, or another
review cycle.

## Risk exceptions

Use a proportionate deeper review, verification, and approval workflow only
when the task involves one or more of the following:

- payments or billing;
- authentication or authorisation;
- an irreversible production database migration;
- security-critical infrastructure;
- a destructive operation such as deleting production data; or
- an explicit owner request for a review-only workflow.

These exceptions are scoped to the risky part of the task and are not a blanket
gate on unrelated work. Continue all safe, reversible work while resolving the
specific risk. Independent Sol review is not a universal requirement; use it
when the owner explicitly requests it or when it is necessary for the named
high-risk action.

## Execution principles

- Optimise for lightning-fast execution, minimal repository scanning, minimal
  context loading, and the smallest correct implementation.
- Read only the code, tests, and reference documents needed for the requested
  change. Do not require a repository-wide audit for a local change.
- Prefer focused regression tests and targeted browser or database checks over
  full-suite validation. Expand verification only when the change is
  cross-cutting or the targeted checks reveal wider risk.
- Reuse evidence that is still applicable; do not repeatedly validate work
  that has already been verified and is unaffected by the change.
- Do not add architecture reviews, security reviews, evidence packs, issue
  ledger entries, traceability rows, or other documentation unless the task or
  the changed product contract genuinely requires them.
- Preserve unrelated user changes and use an appropriate branch or isolated
  worktree when the current working tree is not clean.

## Product memory

The following documents remain useful product references when relevant, but
they are not mandatory reading or mandatory update targets for every task:

1. `docs/product/PRODUCT-TRUTH.md`
2. `docs/qa/OWNER-ISSUE-LEDGER.md`
3. `docs/qa/TRACEABILITY-MATRIX.md`
4. `docs/qa/ROLE-JOURNEYS.md`
5. `docs/qa/REALISTIC-FIXTURES.md`
6. `docs/qa/RELEASE-DEFINITION.md`
7. `docs/release/production-readiness-2026-07-26.md`

Consult and update only the references that materially govern the requested
behaviour. The owner's latest explicit instruction remains authoritative.

## Data handling

Use synthetic customers and businesses in automated or local acceptance work.
Do not place credentials, OTPs, access tokens, real customer PII, production
exports, or temporary screenshot binaries in the repository. Never weaken RLS
or other security controls merely to make a test pass.

## Parallel Claude sessions — coordination protocol (owner directive 2026-08-06)

Multiple Claude sessions work on this product concurrently. Known scopes:

1. **Customer surface** — customer wallet/rewards/bookings/offers UI, customer
   RPC readers, demo-tenant content (Cubbly `8492e8d6-…`).
2. **Business UI/UX** — business console, dashboards, signup/Stripe flows.
3. **Superadmin/platform console** — platform admin, RLS-pause tooling.

Stay inside your scope's files and surfaces. The application script is shared
by all three sessions: keep edits inside your surface's regions and never
reformat or move another surface's code.

**Startup split (2026-08-06):** the former inline megascript now lives in
`app/app.js` (index.html keeps only markup, styles, and the small blocking
config scripts, and loads `/app.js` deferred; `boot()` runs on
DOMContentLoaded). If your in-flight branch still edits the inline script in
`index.html`, rebase and re-apply those edits to `app/app.js` — the code is
byte-identical, only the file moved. Tests that grep application code read the
CONCATENATION of `app/index.html` + `app/app.js` (see the read-site pattern in
any customer-wallet test); new tests must do the same.

### Git and deploys

- Branch from fresh `origin/main`; work in your own worktree, never in another
  session's worktree or the (dirty) `/Users/cs/Downloads/loyalty-main` tree.
- Immediately before any push: `git fetch origin && git rebase origin/main`,
  then fast-forward push (`git push origin <branch>:main`). Never force-push.
  Pushing `main` auto-deploys production; verify `/api/build` afterwards.
- Pinned SHAs in handovers go stale within hours here — always re-verify the
  live SHA at time of use.

### Database and migrations

- Production DB writes run through the Supabase MCP `execute_sql`
  (allowlisted in `loyalty-main/.claude/settings.local.json`). Single-tenant,
  reversible statements only; note every write in your final report.
- Schema/function changes: apply via MCP `apply_migration`, then in the SAME
  commit mirror the file under `db/migrations/`, register it in BOTH
  `db/migrations/migration-order.plan.json` and
  `supabase/canonical-migration-order.plan.json` (use the real ledger version),
  add a `db/tests/vNNN_*.sql` rollback suite, map it in
  `tests/phase0-foundation/pending-migration-preflight.test.mjs`, bump the
  hardcoded counts (materialize script + canonical/manifest tests), and rerun
  `generate-manifest.mjs --write` + `materialize-canonical-order.mjs
  --materialize`. Never replay an already-applied migration.
- Semantic version numbers (vNNN) are claimed by whoever registers first in
  the plan files — check both plans for the highest number before naming.

### Shared browser sessions (important)

- The Claude Browser pane AND the owner's Chrome share one auth session per
  origin. Signing in/out at peekaa.asia clobbers whichever account another
  session (or the owner) is using. Do NOT sign out or switch accounts in a
  shared browser without checking; assume any signed-in session is in use.
- Preferred verification that needs no sign-in: render components in a static
  harness (extract the `<style>` block from `app/index.html`, reproduce the
  exact markup with fixture data, serve from the scratchpad, screenshot light
  and dark — dark requires `html[data-customer-surface="true"]` plus a
  `.customer-surface` wrapper). RPC-level checks can use a captured session
  token via REST without touching localStorage.
- Repeated automated sign-ins trigger Cloudflare Turnstile interactive mode.
  Do not attempt to complete the challenge and do not remove or weaken
  Turnstile — space out sign-ins and reuse sessions instead.

### Cross-session channel

- The shared auto-memory directory
  (`~/.claude/projects/-Users-cs-Downloads-loyalty-main/memory/`) is visible to
  all sessions: record scope claims, in-flight risky work (deploys, migrations,
  account switches), and completed handoffs there, one fact per file, indexed
  in `MEMORY.md`.
- Before deploying or running production SQL, skim `MEMORY.md` for another
  session's in-flight claim on the same surface.
