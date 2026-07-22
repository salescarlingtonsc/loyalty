# P0-REPORTING-SCALE-006 — Reporting pagination, exports, SGT boundaries at scale

## 1. Classification

**ENGINEERING-PREP-COMPLETE** for the algorithmic layer; **OWNER-ACTION-SCRIPTED** for the
production/representative-scale proof.

**Verified today:** `node --test scripts/reporting-scale/reporting-scale.test.mjs` passes 8/8 locally,
covering exactly the shapes this gate cares about: `fetchAllRows` paging correctly past the 1,000-row
API cap (including an exact-multiple boundary and a server cap below the requested page size),
Singapore-local day bounds keeping 23:30 in-day and midnight in the next day, the v17 authorization
helper signatures matching applied definitions, dashboard/report RPCs denying foreign tenant/branch
scope, and that reporting is built on immutable snapshots plus current liabilities rather than
recomputation. This proves the *logic* is correct; it does not prove it holds under production-scale
row counts, which today are near-zero (see `ADVISOR_TRIAGE_2026-07-22.md` — the busiest table, `sales`,
currently estimates 10 rows).

## 2. Preconditions

- A representative-volume fixture (or the rehearsal branch used for `P0-FINANCE-REVERSAL-005`, seeded
  further) with enough rows to exceed the 1,000-row default API page size in at least one report/export
  path — current production has nowhere near that.
- Two browser/OS clock configurations to test SGT vs. non-SGT boundary behavior (or two systems set to
  different local time zones), per the launch-blockers.json success criteria.

## 3. Procedure

1. Re-run the static suite immediately before the scale test to catch regressions:
   ```bash
   node --test scripts/reporting-scale/reporting-scale.test.mjs
   ```
2. Seed the rehearsal branch (or a disposable fixture business) with >1,205 rows in the sales/ledger
   tables that back the dashboard and exports — the v41 audit's own target figure
   (`docs/launch/v41-independent-status-blocker-execution-audit.md`, EVID-004) is ">1,205-row" coverage;
   reuse that bar here.
3. Run every dashboard/report RPC and CSV export against that fixture and confirm no result is silently
   truncated at the API default (1,000 rows) — cursor/paginate through to completion and compare the
   total against a direct `count(*)` on the same filtered set.
4. Reconcile report totals against the ledger/sales snapshot for one full SGT calendar month, including
   the month-boundary day.
5. Run one sale/appointment/report/retention/scheduled-job case immediately before and after SGT
   midnight, from both an SGT-clock browser and a non-SGT-clock browser, and confirm the record lands in
   the correct SGT business day in both cases (this overlaps `P0-SGT-TIMEZONE-013`; a single combined
   drill can satisfy evidence for both gates — see `INDEX.md` critical path).
6. Time the longest report query in the fixture and confirm it is within whatever operational limit the
   owner has agreed to (not yet stated anywhere in the repo — if no limit has been agreed, treat this as
   an open OWNER-DECISION sub-item and record the observed duration as a baseline instead of a pass/fail).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-REPORTING-SCALE-006.json`
- Example `checks`: `{"staticSuitePassed": true, "noSilentTruncationAtApiDefault": true,
  "monthlyTotalsReconcile": true, "sgtBoundaryCorrectBothClocks": true,
  "queryDurationWithinAgreedLimit": true}`
- `summary`: row counts, durations, and pass/fail only — no customer names or raw export contents.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

2-3 hours, dominated by fixture seeding and the two-timezone boundary drill.
