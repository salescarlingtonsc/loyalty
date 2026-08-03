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
