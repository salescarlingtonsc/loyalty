# Nestly QA evidence system

Use these documents in this order:

1. [`../product/PRODUCT-TRUTH.md`](../product/PRODUCT-TRUTH.md) — confirmed
   product decisions.
2. [`OWNER-ISSUE-LEDGER.md`](OWNER-ISSUE-LEDGER.md) — every owner complaint and
   its lifecycle.
3. [`TRACEABILITY-MATRIX.md`](TRACEABILITY-MATRIX.md) — requirement-to-surface,
   data, test, and evidence mapping.
4. [`REALISTIC-FIXTURES.md`](REALISTIC-FIXTURES.md) — reusable sector-specific
   data.
5. [`ROLE-JOURNEYS.md`](ROLE-JOURNEYS.md) — complete acceptance journeys.
6. [`RELEASE-DEFINITION.md`](RELEASE-DEFINITION.md) — what may be claimed at
   each evidence level.

The ledger is append-only for issue identity: correct or supersede an entry,
but do not erase the fact that the owner reported it. Temporary screenshot
paths are not durable, so record the visible symptom and context in the ledger.

For each implementation task:

1. update the ledger and traceability matrix;
2. reproduce with a realistic fixture;
3. implement;
4. add a regression;
5. perform applicable browser/database/cross-role verification;
6. attach evidence;
7. request independent review.
