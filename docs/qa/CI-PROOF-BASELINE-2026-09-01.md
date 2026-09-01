# Customer Intelligence — 100-point proof baseline

**Frozen commit:** `d6f67327` (branch `claude/ci-proof-100`, cut from `origin/main`)
**Harness commit:** `f1ed6175` (the unblock described in §2)
**Date:** 2026-09-01
**Method:** read-only source and SQL audit of the frozen tree, five independent passes, every claim cited to `file:line`. No production database was accessed.
**Reviewer:** not yet assigned. This document is *input* to an independent review, not a verdict.

---

## 1. Score

**1 / 100.**

| Status | Count | Meaning |
|---|---:|---|
| `BUILT_AND_EXECUTED` | **1** | Capability exists *and* a test executes it. Scores a point. |
| `BUILT_UNPROVEN` | 12 | Demonstrably exists in code; no executing test. Scores zero. |
| `PARTIAL` | 37 | Some sub-requirements met. Scores zero. |
| `ABSENT` | 50 | Not implemented. Scores zero. |

The single earned point is **check 14 (comparison baseline named with its value)**, proven by `tests/business-ui/v550-recovery-report.test.mjs`, which loads the real `recoveryReportHtmlV550` function via `vm.runInContext` and executes it against fixtures — real execution, not a source grep.

This score is not a measure of how much has been *built*. It is a measure of how much has been **proven**, which is what the checklist asks for. A great deal is built. Almost none of it is proven.

### Absences by section

| Section | Absent | Theme |
|---|---:|---|
| A — Data truth | 2/10 | Strong foundations, no executed proof |
| B — Definitions & traceability | 1/10 | Rich contracts; the trace ID (20) does not exist |
| C — Discovery | 8/10 | No discovery or ranking layer exists |
| D — Demographics/time/staff | 8/10 | Capture exists; analytics do not |
| E — Lifecycle & prediction | 6/10 | Cadence is strong; no funnel, no calibrated prediction |
| F — Rebooking/loyalty/discounts | 5/10 | Facts recorded, largely unread |
| G — Statistics | 3/10 | Real intervals, no central discipline |
| H — Recommendations | 6/10 | One opportunity class only |
| I — AI safety | **9/10** | Prompt instructions, not output validators |
| J — Access & ops | 2/10 | Gates exist; contracts and isolation unproven |

---

## 2. The blocker found and fixed during this audit

**The executed-SQL harness never reached the Customer Intelligence layer.**

`scripts/db-tests/run.mjs` is the only harness in this repo that runs real SQL against a real Postgres engine. Its migration chain **halted at v599**, and every later migration was silently skipped. No `v6xx` migration applied — meaning v620–v665, including the entire intelligence layer v628–v652, was invisible to the only place that executes anything. The suite still reported *"all executed SQL passed"*, because a skipped migration is not a failing test.

Three faults, each hiding the next:

1. `tests/fixtures/db-schema-snapshot.sql` is dumped with `--no-privileges` ([snapshot-schema.mjs:149](../../scripts/db-tests/snapshot-schema.mjs)), so the restored baseline granted `anon` / `authenticated` / `service_role` **nothing**. v599 revokes a specific privilege set then asserts the surviving ACL; against a privilege-less baseline that post-condition can never hold.
2. The pg_cron stub's `cron.job` had no `active` column, so v601's `cron.alter_job(active => false)` raised 42703.
3. `cron.alter_job` and `cron.job_run_details` were not stubbed at all, though the chain calls them 3 and 9 times.

Fixed in `f1ed6175`. The chain now applies through v665 and the executed suite passes.

**The privilege gap was the dangerous one.** A tenant-isolation test run as `authenticated` against a baseline where that role holds no grants passes *for the wrong reason*: it proves the role can read nothing anywhere, not that policy scopes it to its own tenant. Restoring the grants is what makes `set local role authenticated` mean what it says. Any isolation evidence produced before this fix should be treated as void.

---

## 3. Confirmed defects (shipping now, not hypothetical)

### 3.1 Consultant report renders fallback zeros — check 93

Exact key comparison between emitted JSON and UI reads:

| Surface | SQL emits | UI reads | Result |
|---|---|---|---|
| Affinity pairs | `support_orders`, `confidence_pct` | `orders_together`, `attach_rate_pct` | Table renders `0` / `0.0%` |
| KPI tiles | `visits`, `returning_customers` | `transaction_count`, `returning_rate_pct` | Tiles render `0` |
| Customer groups | `cohorts.{definitions,counts}` (object) | `customer_intelligence.cohorts` (array) | Table renders empty |

Live SQL at `db/migrations/20260728_nestly_v94_platform_control_intelligence.sql:2137,2165`; UI at `app/platform-console.js:5521-5555`. The UI reads names from a **dead earlier definition** at `v94:1745-1825` that was superseded at `:2063-2192`. Net effect: Returning rate, Transactions, the entire affinity table and the entire customer-groups table render zero or empty **regardless of real underlying data**. Only Customers and Revenue render correctly.

### 3.2 "Consultant-only" CI RPCs are reachable by ordinary staff — check 91

`docs/product/PRODUCT-TRUTH.md:228` declares Customer Intelligence platform-only, and `v246:97` hard-disables the `customerintel` module key for every business — the SPA route is correctly unreachable. But `app.ci_reports_gate_v650` ([v650:16-27](../../db/migrations/20260831_nestly_v650_ci_read_layer.sql)) gates the `get_ci_*` RPCs on the ordinary **`reports`** module, not `customerintel`. Any authenticated staff member with normal reports access can call them directly over REST, bypassing the UI. The front-end story is not backed by matching server-side authority.

### 3.3 Customer names disclosed with no small-cell suppression — check 96

`get_ci_category_customers_v1` ([v650:138-182](../../db/migrations/20260831_nestly_v650_ci_read_layer.sql)) returns raw `full_name` for a filtered category with **no minimum-group-size threshold**. A category containing one customer directly identifies that person. The AI evidence pack does this correctly by contrast, using abbreviated labels via `app.v177_person_label` (`v179:162`).

### 3.4 No CI RPC accepts a branch parameter — check 95

Every one of the six `get_ci_*` functions filters by `p_business` only. Branch isolation is not weakly enforced; it is **not implemented** in this module. A branch-restricted staff member who can reach reports sees business-wide figures.

---

## 4. Correction to the prior assessment

An earlier assessment scored this work 38/100 and was dismissed in review as stale, on the grounds that Phase A–D had since landed and closed the "missing raw authority" gaps. **That dismissal was wrong, and this audit retracts it.** Migration filenames promised capability the code does not deliver:

| Filename suggests | Code actually contains |
|---|---|
| `v638_demographics_authority` | A **single-customer** lookup (`p_client uuid` → one age band/gender). No aggregation. **Zero callers.** |
| `v632_rebooking_link` | A write-once provenance column with **zero readers** anywhere in the repo. |
| `v635_attribution_associations` | A schema-only contract; its own header says *"no production job writes here yet."* |
| `v628_analytics_exclusions_watermarks` | An exclusion authority its own same-day siblings (v629, v650) do not call — each reimplements its own filter. |

The original assessment was directionally correct. The lesson is the one this checklist already encodes: **a filename, a migration, and a merged commit are not evidence.** Only execution is.

The genuine standout is `v629_first_acquisition` (check 59) — every customer-creation path governed, `unknown` a first-class value, a write-once guard, and a real UI consumer. It fails only for want of an executed test.

---

## 5. What the score is *not* saying

Real strengths exist and should survive any rebuild:

- `get_revenue_truth_v106` implements a rigorous canonical population (reversal-aware residuals, half-open periods, per-outlet timezone, as-of cutoff) with a **server-side invariant that raises** if identified + anonymous ≠ known revenue.
- `app.customer_cadence_v1` (v651) is a genuine per-customer cadence authority. Traced by hand, it **does** rank a 7–10-day-rhythm customer 20 days idle above a 50–65-day-rhythm customer 20 days idle (check 48) — the behaviour the checklist asks for. It has no caller and no test.
- v108's treatment/holdout engine is real causal machinery, and it **honestly labels its own confidence** as `'score_kind','data_quality_only'` — not a success probability.
- v108 withholds expected value as `'status','withheld_uncalibrated'` rather than fabricating one.

---

## 6. Highest-severity systemic gaps

1. **Section I is prompt-instruction, not validation (9/10 absent).** The AI report asks the model not to invent numbers (`ai-firm-reports/index.ts:100`) but no code inspects the output. There is no numeric validator, no population validator, no causal-language blocker, no confidence ceiling, no limitation-preservation check, and no hallucination suite. A deterministic validator exists (`app.evidence_block_v1`) but guards a *different*, SQL-rendered report.
2. **No central sample-size discipline (check 61).** Three inconsistent hardcoded floors (5, 10, and a 20-txn/10-customer/4-week combination) in three engines. The v179 at-risk cohort that the AI report narrates has **no floor at all** — a 1-customer cohort gets a rate and a dollar figure as confidently as a 500-customer one.
3. **Wald intervals on proportions (check 63).** Both v108 and v652 use an unadjusted normal approximation — precisely the interval the checklist calls unreliable at small or extreme samples.
4. **No golden corpus (check 10).** The nearest artifact, `db/tests/executed/v422_customer_intelligence_scale.sql`, is 199 *empty* filler businesses for timing, not sector-diverse reconciliation.
5. **One opportunity class (check 72).** `recommendation_type` is CHECK-constrained to exactly `'lapsed_high_value_bring_back'`. Nothing can outrank it because nothing else exists.

---

## 7. Path to 100/100

Three checks cannot be earned by engineering alone and require the parties the owner has confirmed available: **#80** (blinded senior-reviewer panel), **#99** (authorized production-shadow window), **#100** (independent Sol acceptance against a frozen commit).

Of the remaining 97:

| Band | Checks | Nature of work |
|---|---:|---|
| Executable proof for what already exists | ~13 | Write `db/tests/executed/*.sql` fixtures. Cheapest band by far — now unblocked by `f1ed6175`. |
| Complete a partial build | ~37 | Wire an unread authority to a reader, add a missing field, render a computed-but-dropped value. |
| Build from scratch | ~47 | Discovery layer, retention funnels, demographic analytics, calibration, AI output validators, golden corpus. |

The ordering constraint that matters: **the synthetic corpus (check 10) gates most of the rest.** Nearly every other check's proof gap is phrased as "an executed test asserting X", and those tests need predetermined-answer fixtures to assert against. The corpus is the next build, not a later one.

---

## 8. Proof-pack artifact status

| # | Artifact | Status |
|---:|---|---|
| 1 | Frozen commit SHA + migration ledger | **Done** — `d6f67327`; ledger now replays to v665 |
| 2 | Capability-to-query map | **This document** |
| 3 | Versioned metric dictionary | Not started (check 11 is PARTIAL) |
| 4 | Synthetic corpus manifest | Not started — **next** |
| 5 | Expected-answer file | Not started |
| 6–13 | Results, reconciliation, statistical review, AI factuality, isolation, screenshots, test outputs | Not started |
| 14 | Known-limitations register | This document is its first entry |
| 15 | Independent Sol acceptance | Awaiting owner routing |
