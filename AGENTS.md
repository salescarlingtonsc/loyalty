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

## Peekaa Permanent Bug-Closure Protocol (owner directive)

Every production bug should make Peekaa permanently harder to break. Convert
the knowledge from each defect into an automated guard wherever feasible, so
the owner never has to manually rediscover the same class of inconsistency.
Whenever a bug is reported, automatically assess whether it warrants (A) an
acceptance regression, (B) a tenant scanner rule, and/or (C) lifecycle
certification — and do so without waiting for the owner to ask.

A bug is closed only when all nine layers below have been considered, not
merely when the screenshot looks right, the affected tenant works, a row was
backfilled, or the suite is green.

1. **Fix the live symptom.** Restore correct behaviour for the affected
   customer/business; verify the REAL production reader/output after the fix.
2. **Find the defect class.** Determine why the invalid state was possible.
   Never conclude "tenant X had bad data"; determine "what system behaviour
   ALLOWED tenant X to acquire that shape, and can another tenant acquire it?"
   Prefer fixing the writer, authority, invariant, or lifecycle that created
   the bad state.
3. **Add an acceptance regression.** An executable test reproducing the exact
   failure shape; it must fail against the old behaviour, pass after the fix,
   and exercise BEHAVIOUR rather than merely grepping source where practical.
4. **Extend the production divergence scanner**
   (`db/tests/tenant_divergence_scan.sql`). Ask "can this failure already
   exist silently in another tenant?" Add a rule detecting the invalid state
   estate-wide. CRITICAL: do not only test whether two readers agree — test
   whether the readers are CORRECT against the canonical business rule. Two
   wrong readers agreeing is still a bug. Classify findings: runtime-dangerous
   → blocking; intentional documented exception → explicit scoped waiver
   (never broad/global waivers); historical/informational → non-blocking.
5. **Extend lifecycle certification**
   (`db/tests/tenant_lifecycle_certification.sql`) if the bug represents a
   state transition or lifecycle scenario — for example: new tenant creation;
   programme ON/OFF; Points↔Stamps; publish after an unrelated settings
   change; stale draft; reward becoming claimable; reward becoming
   non-claimable; customer earns before/after configuration;
   birthday/welcome/referral configuration; redemption; programme switching.
6. **Check all tenants.** Run the scanner, identify affected tenants,
   backfill only where necessary, make backfills auditable and idempotent
   where practical, and verify zero unexplained runtime-dangerous divergence
   afterward. Never repair tenants one by one without closing the source of
   corruption.
7. **Validate canonical correctness.** For important business state (current
   programme; active/off; balance; stamp target; earning rate; claimability;
   reward eligibility; expiry) define the canonical answer and have all
   consumers derive from the same authority/core where practical.
   `Reader A == Reader B` is NOT sufficient evidence; require
   `Reader A == Reader B == canonical business rule`.
8. **Fail closed.** Missing or contradictory required production state must
   never be hidden with cosmetic defaults. Defaults may initialise a NEW
   DRAFT; defaults must not fabricate live production state. If live
   configuration is invalid, prevent publish or return an explicit internal
   configuration failure.
9. **Permanent closure standard.** A bug is CLOSED when protections exist
   across all of: live repair + root cause + regression test + scanner
   coverage + lifecycle certification + estate-wide verification.

### Commands

- `npm run tenant-gate` — runs the divergence scanner (layer 4).
- `npm run tenant-gate:prove` — proves the scanner can still detect an
  injected divergence (a gate on the gate).
- `npm run certify-tenant` — runs the lifecycle certification (layer 5).

Full command behaviour, when each MUST run, and verdict semantics are in
`docs/design/ps0/TENANT_CONSISTENCY_GATES.md`.

### Worked example: nestly_v568

A consistency check comparing two readers becomes tautological the moment one
reader delegates to the other — it can then only see disagreement, never a
defect both readers inherit. `reward_availability_v432` let a parked points
gift render "READY" because its closed-cycle arm skipped the programme-id
join; the existing scanner check couldn't catch it because it only compared
readers, not the rule. Fix: scanner check D16 now states the rule directly
against the availability core's own answer — no reward may be offered while
its own programme is off.

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

**After ANY edit to `app/app.js`, run `npm run bundle-stamp`.** As of v185 that command also
splits the file into surface bundles — `app-core.js` (always), `app-customer.js`,
`app-business.js`, `app-i18n.js` — which are GENERATED and must never be edited by hand. Keep
editing `app/app.js`; the build partitions it. A symbol either surface can reach is placed in the
core automatically, so cross-surface helpers keep working; a test fails if any chunk ends up
referencing another chunk's symbol. The script tag
carries a fingerprint of the bundle's bytes (`/app.js?b=<hash>`) because
Cloudflare rewrites the browser-facing `max-age` on that file to four hours no
matter what Vercel sends — without a changing url, a returning visitor runs the
previous deploy's application code against the new `index.html`. Three tests in
`tests/phase0-foundation/app-bundle-stamp.test.mjs` fail if the stamp drifts,
and `npm run validate` checks it.

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
