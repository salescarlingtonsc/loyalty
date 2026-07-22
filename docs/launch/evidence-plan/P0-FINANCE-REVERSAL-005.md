# P0-FINANCE-REVERSAL-005 — Sale reversal, refund, and store-credit tender integrity

## 1. Classification

**OWNER-ACTION-SCRIPTED.** v20 (financial engine) and v40 (staff reversal workflows) are already
applied to `gadpooereceldfpfxsod` (confirmed via read-only `list_migrations`:
`frenly_v20_financial_engine`, `frenly_v40_staff_reversal_workflows` both present). The correctness and
concurrency test suites already exist in the repo; a human with a disposable/rehearsal database
connection needs to run them and reconcile the result.

## 2. Preconditions

- **Two different test-execution modes, do not conflate them:**
  - `db/tests/v20_financial_engine.sql` and `db/tests/v40_staff_reversal_workflows.sql` are
    single-transaction, rollback-safe correctness suites (same pattern as
    `rls_adversarial_isolation.sql`) — these can run directly against production inside a `begin;
    ... rollback;` block.
  - `db/tests/v20_financial_concurrency.sh` and `db/tests/v40_reversal_credit_concurrency.sh` spawn
    **multiple concurrent connections** to race real transactions against each other and cannot be
    wrapped in one rollback. Both scripts refuse to run unless `V20_CONFIRM_DISPOSABLE_DB=YES` (or the
    v40 equivalent) is set — confirmed by reading their source. **Do not point these at production.**
    Provision an isolated rehearsal branch first (Supabase branching, created by the release engineer —
    not this agent, since branch creation is a write action).
- `DATABASE_URL` and `PGPASSWORD` set per the scripts' own validation (they reject a URL containing an
  embedded password and require `PGPASSWORD` separately — confirmed by reading
  `v20_financial_concurrency.sh`).
- **OWNER-DECISION precondition named in the manifest's own success criteria:** confirm which
  tenders/reversal shapes are actually supported for launch (full refund, partial-refund rejection,
  store-credit tender) versus deliberately unsupported and hidden from the UI — this should already be
  settled by the v20/v34/v40 design, but the owner should sign off that the *current* UI does not expose
  a reversal control for any case the engine rejects.

## 3. Procedure

1. Rollback-safe correctness suites, directly against production, each in its own transaction that is
   rolled back at the end (read the file first to confirm it ends in `rollback;` or wrap it yourself):
   ```bash
   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/tests/v20_financial_engine.sql
   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/tests/v40_staff_reversal_workflows.sql
   ```
2. Concurrency suites, against an isolated rehearsal branch only:
   ```bash
   export V20_CONFIRM_DISPOSABLE_DB=YES
   export DATABASE_URL="<rehearsal-branch-url>"
   export PGPASSWORD="<rehearsal-branch-password>"
   sh db/tests/v20_financial_concurrency.sh
   sh db/tests/v40_reversal_credit_concurrency.sh
   ```
   Confirm the same-key tender-replay and competing-credit-balance races both resolve to exactly one
   applied effect, matching the "PASS" results already recorded for local rehearsal in
   `docs/launch/V49A_REHEARSAL_REMEDIATION_RESULTS_2026-07-22.md` ("v20 same-key tender replay and
   competing credit balance race: PASS").
3. Reconciliation pass: for each supported correction (full refund, over-refund denial, duplicate
   submission, store-credit tender, cross-tenant denial), confirm revenue, receivables, payments, cash,
   points, credit, referral, inventory, and commission all reconcile to zero drift after the correction,
   per the success criteria in `launch-blockers.json`.
4. UI/engine agreement check: confirm the UI does not present a reversal/refund control for any
   partial or value-redemption case the engine explicitly rejects (manual click-through, or extend
   `tests/financial-integrity/` if a static assertion is feasible).
5. Role-gate check: attempt a reversal as a role without reversal permission and confirm denial; attempt
   a direct table `INSERT` into a ledger table bypassing the RPC and confirm it is rejected (grant-level,
   already partially evidenced under `P0-RLS-GRANTS-004`).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-FINANCE-REVERSAL-005.json`
- Example `checks`: `{"v20CorrectnessSuitePassed": true, "v40CorrectnessSuitePassed": true,
  "v20ConcurrencyRacePassed": true, "v40ConcurrencyRacePassed": true, "reconciliationZeroDrift": true,
  "unsupportedCasesRejectedAndHiddenFromUi": true, "roleGateDenied": true,
  "directLedgerInsertDenied": true}`
- No dollar amounts tied to real customers, no real business/customer identifiers — use synthetic
  fixture labels and aggregate pass/fail counts only.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

1.5-3 hours, dominated by provisioning the isolated rehearsal branch for the concurrency harnesses (the
correctness suites and reconciliation pass are fast once a connection exists).
