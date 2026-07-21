# Frenly v25-v35 Local Acceptance Record

Date: 2026-07-20 (Asia/Singapore)
Branch: `codex/phase0-transaction-foundation`
Baseline: `main@a71178a`
Production target: `gadpooereceldfpfxsod` (Singapore)

Reviewer verdict: **CHANGES REQUIRED**

## Foundations implemented locally

- Required module dependency resolution and owner-controlled module changes.
- Required idempotency keys for financial redemption and package-session operations.
- Atomic, owner-authorized backend import jobs for customers, services, inventory, staff,
  branches, and reservation capacity. Rows are tenant-bound to their job and exact repeated
  setup records are rejected during preview.
- Draft-first onboarding; immutable configuration versions for program terms, reward catalogs,
  and tier multipliers; explicit preview, publish, and supersession; live loyalty projections
  cannot be edited directly.
- Rich reward configuration, normalized eligibility, per-firm reward labels, branch overrides,
  and typed custom customer fields.
- Customer identity, verified business links, exact-match claims, invitations, unlink audit,
  per-firm wallet, appointment actions, and business-scoped notification preferences.
- Immutable package-session consumption/restoration evidence and exact loyalty redemption
  operation, ledger, credit, and FEFO batch-drain provenance.
- Owner-only recommendation generation into an inactive, editable draft. Recommendations never
  auto-publish and do not read customer PII.

## Security and financial corrections found during review

- Removed the owner write policy and browser write privileges that could bypass immutable loyalty
  configuration publication.
- Tier multipliers now follow the same draft, hash, publish, and supersession contract as program
  terms; browser roles cannot mutate the live tier projection directly.
- Notification opt-outs now suppress booking-update outbox events; absent consent defaults to the
  transactional in-app event, and the provider feature flag remains fail-closed.
- Zero-credit historical reward claims retain `manual_item` meaning instead of being rewritten as
  store-credit claims.
- Import rows now have a composite `(job_id, business_id)` foreign key and commit filtering.
- Package-session retries are serialized by business and idempotency key; zero-dollar reversals
  require exact immutable package evidence and never create a payment refund.
- Loyalty claim reversal restores only proven FEFO drains, appends compensating ledgers, and blocks
  a credit clawback after the granted credit has been spent.

## Verification completed

- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`: PASS.
- Static quality baseline: PASS.
- Node test suite: 164/164 PASS.
- Static release build: PASS for `data-request.html`, `index.html`, `join.html`, `privacy.html`,
  and `terms.html`.
- `git diff --check`: PASS.
- No production migration, deployment, commit, push, or feature enablement was performed.

## Release-blocking implementation gaps found in final review

1. The customer identity and relationship backend has no complete product journey: there is no
   `/#/claim` route, customer identity creation flow, invitation/email claim UI, unlink UI,
   server-derived persona resolver, dual staff/customer switcher, or signed-in state layered onto
   the direct business portal.
2. Draft reward eligibility is not safely editable. Eligibility child-table RLS exposes only the
   active configuration, while the draft UI reads unscoped rows and indexes them using the reward
   version ID instead of the stable reward ID. Editing a draft can therefore display blank
   restrictions and publish an unintentionally unrestricted reward.
3. The per-firm wallet exposes balances and counts, but not the approved reward catalog, loyalty
   activity, redemption/grant history, or useful package details. The customer MVP is not an
   end-to-end retention journey yet.
4. Package, sale, and loyalty reversal RPCs exist, but no permission-aware staff workflow invokes
   them or displays compensating history. SMEs cannot perform the supported correction through the
   application.
5. Branch-level loyalty overrides exist in the database but have no owner editor or preview.
   Retention programs still mutate their live rows directly instead of following the immutable
   draft, hash, publish, and supersession contract.
6. The 164 Node tests are primarily static contract checks. They do not substitute for executing
   the SQL behavior suites and concurrent journeys on a disposable production-equivalent database.

The ordered closure contract and worker handoffs are recorded in
`docs/launch/v36-v41-remediation-contract.md` and
`docs/launch/v36-v41-worker-prompts.md`. The requirement-by-requirement proof status is
tracked in `docs/launch/v25-v41-evidence-matrix.md`.

## Acceptance limits

This record inventories the local foundations for continued integration review. It does not accept
the implementation phase or production release. The implementation gaps above and the following
gates remain authoritative:

1. The repository does not contain executable historical migrations for every production object
   (notably v5, v6, and v15 are represented by note files). A fresh database cannot yet be proven
   reconstructible solely from this repository.
2. The v25-v35 SQL rollback suites have not been executed against a disposable database containing
   the complete production-equivalent migration chain and fixture set.
3. Customer wallet, action, and notification database feature flags default to disabled. Frontend
   flags also remain disabled. Enabling them requires a separate accepted release step.
4. `docs/launch/launch-blockers.json` remains the production launch authority. Local tests do not
   convert blocked P0 gates into production evidence.
5. Retention recommendations are deterministic catalog heuristics. They do not yet claim causal
   sales uplift and do not use cohort history, capacity utilization, or inventory velocity.

## Required next release step

Restore the missing historical migrations or create a production-schema baseline, build a
disposable Singapore-region verification database from that source, execute every v20-v35 rollback
suite plus concurrency tests, review the resulting catalog ACL/RLS snapshot, and only then prepare a
separate production migration and feature-flag rollout.
