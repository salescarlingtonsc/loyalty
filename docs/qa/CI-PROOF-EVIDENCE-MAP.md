# Capability-to-evidence map

Proof-pack artifact #2. One row per acceptance check whose status changed since the
2026-09-01 baseline, naming the artifact that proves it and the assertion key inside that
artifact. A check earns `BUILT_AND_EXECUTED` only when a named assertion executes the code it
covers — a source-regex never qualifies.

Every executed fixture below is **mutation-checked**: an expected value is deliberately altered,
the run is confirmed red, and the file restored. An assertion that cannot fail proves nothing,
and this repo has shipped that mistake before.

## Changed by the v667 P0 wave

| Check | Was | Now | Evidence | Assertion |
|---:|---|---|---|---|
| 12 · numerator and denominator on every percentage | PARTIAL | **BUILT_AND_EXECUTED** *(consultant brief only)* | `tests/platform-console/v667-consultative-payload.test.mjs` | "the returning rate is derived and shows its numerator and denominator" — asserts `25.0% (10/40)` |
| 92 · UI/RPC contract validation | ABSENT | **BUILT_AND_EXECUTED** | same file | "CONTRACT: every payload key the renderer reads is one the SQL emits" |
| 93 · consultant report defect closure | PARTIAL | **BUILT_AND_EXECUTED** | same file | 6 render assertions; 0/8 before the fix, 8/8 after |
| 94 · tenant isolation | BUILT_UNPROVEN | **BUILT_AND_EXECUTED** | `db/tests/executed/v667_ci_access_boundaries.sql` | `B2` — another firm's owner is refused 42501 |
| 95 · branch isolation | PARTIAL | **BUILT_AND_EXECUTED** | same file | `B4` exact branch revenue (25000 vs 34000 firm-wide); `B5` foreign branch refused |
| 96 · privacy and small-cell protection | PARTIAL | **BUILT_AND_EXECUTED** | same file | `B6` a 1-customer cohort names nobody; `B7` an at-floor cohort still answers |
| 98 · failure behaviour fails closed | BUILT_UNPROVEN | **PARTIAL** | same file | every refusal asserted as 42501, never an empty payload. Model/export failure paths still unproven |

`B1`/`B3` additionally prove the entitlement contract in both directions — a firm owner refused,
the assigned consultant and super admin served. That pair has no single checklist number; it is
the correctness of check 91's authority, which remains **PARTIAL** because the merchant-versus-
platform surface question is an owner decision, not a test result.

## Changed by the synthetic corpus

| Check | Was | Now | Evidence | Assertion |
|---:|---|---|---|---|
| 59 · acquisition authority | BUILT_UNPROVEN | **BUILT_AND_EXECUTED** | `db/tests/executed/v629_corpus_acquisition_demographics.sql` | `A1` all 9 paths bucketed with exact counts; `A2` `unknown` never NULL; `A3` write-once raises 42501; `A4` synthetic excluded from bucket and total |

*Remaining corpus fixtures are in progress and will be added here as they land and are verified.*

## Findings recorded, not silently fixed

| Finding | Where | Why it is not a fix |
|---|---|---|
| No business-wide demographic coverage exists anywhere | `v629_corpus_…` inline note | `app.customer_demographics_v1` is a single-customer lookup. Checks 31–34 stay ABSENT; the migration filename oversold the capability and the earlier assessment was right |
| 15 executed tests fail once the chain applies | `docs/qa/audit-artifacts/v667-suite-delta-2026-09-01.md` | Patching fixtures in the same pass that repaired the chain would be indistinguishable from concealing a regression |
| The evidence interval is an unadjusted Wald interval | proof baseline §6 | Changing the statistical method is a product decision, not a test repair |

## What this map is not

It does not claim a revised total. The score is recomputed only after every corpus fixture is
green and mutation-checked, and it is reported as the same four separate numbers the owner ruled
on — proven, implemented-but-unproven, partial, absent — never merged.

## Superseded note (2026-09-02)

The "No business-wide demographic coverage exists anywhere" row above (checks 31–34 ABSENT) was
true when this map was written. `db/migrations/20260902_nestly_v674_demographic_intelligence.sql`
(`db/tests/executed/v674_corpus_demographics.sql`) now claims to close checks 31–34 with a real
aggregate reader and the flagship cohort-vs-baseline RPC. That claim has not been independently
re-verdicted by a refuter round in the material available to this update, so it is recorded as
**BUILT, not re-confirmed** rather than silently marking the old row fixed.

## Full 100-check pass

A complete, check-by-check walk of all 100 checklist items (not only the ones that changed since
the baseline) — artefact, exact command, predetermined truth, and provisional ledger status for
each — is recorded separately in
[`docs/qa/CI-PROOF-EVIDENCE-MAP-2026-09-02.md`](./CI-PROOF-EVIDENCE-MAP-2026-09-02.md), because
the table shape here (only changed checks, terse) does not fit a full 1–100 pass without losing
the "what changed and why" focus this file was built for. That file also carries the "Declared
limits" section for the validator (checks 17/83/85/88) and the "Pre-existing failures found and
repaired" section for commits `e9963c31` and `bfb69dcb`.
