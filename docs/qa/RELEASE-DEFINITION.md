# Nestly release and completion definition

This document prevents a code pass from being reported as product completion.

## Evidence levels

| Claim allowed | Minimum evidence |
| --- | --- |
| "Implemented" | Code exists and targeted static/unit checks pass. State remains `IMPLEMENTED_UNVERIFIED`. |
| "Verified locally" | Exact regression passes locally with realistic fixture. |
| "Browser verified" | Named role journey passes in a real browser at required desktop/mobile viewports with artifact and candidate hash. |
| "Database verified" | Persistent before/after records and cross-surface projections pass in the named non-production or authorized target environment. |
| "Production verified" | Authorized version is deployed and the exact smoke/monitoring evidence is attached. |
| "Closed" | All acceptance criteria have their required evidence, traceability is complete, and Sol independently accepts the scope. |
| "Production-ready" | Every in-scope release row is closed, all mandatory launch gates pass, rollback/monitoring are ready, and there is no unresolved P0/P1 or unverified required behavior. |

Do not use a higher claim when only a lower evidence level exists.

## Feature completion gate

For every in-scope issue:

- exact acceptance criteria are recorded;
- a realistic fixture reproduces the original complaint;
- regression test fails before and passes after the fix;
- owner -> staff -> customer path passes when applicable;
- server authorization is checked, not only navigation visibility;
- disabled, empty, denied, retry, refresh, mobile, and branch states required by
  the matrix pass;
- database persistence and idempotency are proven for writes;
- evidence paths and candidate hash are recorded;
- Sol's independent verdict is recorded.

## Release candidate gate

- full test suite for the candidate is green;
- build/type/lint/quality gates are green;
- canonical migration manifests and checksums match;
- pending migrations are rehearsed in a disposable environment;
- production migrations and rollback order are explicit;
- the existing launch blocker manifest and P0 evidence plan are clear;
- secrets, providers, backups, observability, and operational alert recipients
  are verified without exposing secret values;
- accessibility, responsive layouts, and critical browser/device paths pass;
- no temporary debug bypass, fake production data, or misleading placeholder is
  shipped;
- release notes identify verified, deferred, and blocked items separately.

The operational baseline in
[`../release/production-readiness-2026-07-26.md`](../release/production-readiness-2026-07-26.md)
remains part of this gate.

## Production release gate

1. Sol independently reviews the exact candidate and accepts its scope.
2. The owner gives release approval naming that candidate/phase.
3. Only then may authorized operators perform production migration/deploy
   actions.
4. Verify the served commit/build, migrations, role access, and critical smoke
   journeys.
5. Monitor for the approved window and attach alerts/error/business-event
   evidence.
6. Mark only the rows actually verified in production as
   `VERIFIED_PRODUCTION` or `CLOSED`.

Approval for one version does not authorize unrelated later work.

## Automatic stop conditions

Do not claim production readiness or proceed to release when any of these is
true:

- a required row is `CAPTURED`, `REPRODUCED`, `IMPLEMENTED_UNVERIFIED`, or
  `BLOCKED`;
- an owner complaint has no traceability row;
- browser mocks are the only proof for a persistent write;
- a hidden control remains callable by a denied role;
- retries or double actions can duplicate money, points, packages, vouchers,
  bookings, or relationships;
- customer and business surfaces disagree after reload;
- the candidate being reviewed differs from the candidate being released;
- release evidence contains real credentials or customer PII.
