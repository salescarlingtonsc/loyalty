# Nestly Growth Build Plan

**Date:** 2026-07-30
**Basis:** Frozen workspace audit at `6226777e34c41ac1bc5f6ec10edd13332e17c929`
**Constraint:** This is a plan only. No implementation or production change was performed.

## Strategy

Nestly should not expand horizontally into more “AI insights” or campaign types yet. The shortest path to commercial proof is:

```text
TRUSTWORTHY COVERAGE
→ PRECISE CUSTOMER LIFECYCLE
→ ONE RANKED OPPORTUNITY
→ ONE GUARDED EXECUTION
→ ONE DEFENSIBLE RESULT
```

The plan contains exactly 3 P0, 5 P1, and 5 P2 items. P0 establishes truth. P1 ships the first measurable loop. P2 adds breadth only after the loop is trusted.

## Smallest viable closed-loop product

### Measured Bring-Back Loop v1

**User story:** Each morning, an owner sees one evidence-backed group of customers whose observed visit cadence has lapsed, the estimated revenue opportunity and cost, and one safe offer. The owner previews, approves, and sends it. Nestly preserves a holdout, tracks delivery and purchases, then reports a confidence-qualified incremental-revenue result.

**Required sequence**

1. Verify transaction and identity coverage.
2. Calculate a server-side lapse segment using versioned cadence rules.
3. Create a recommendation with evidence, expiry, expected revenue range, confidence, cost cap, and exclusions.
4. Preview eligible, excluded, treatment, and holdout counts.
5. Recheck consent and frequency suppression.
6. Send through one provider/channel with status and retry.
7. Issue a single-use entitlement tied to campaign/customer/recommendation.
8. Link subsequent transactions automatically.
9. Evaluate intent-to-treat lift when valid; otherwise show associated revenue and “inconclusive.”
10. Show result and store owner decision/outcome for calibration.

**Deliberate limits**

- One recommendation type.
- One channel.
- One active measured campaign per customer.
- Incremental revenue, not profit.
- No generated financial math.
- No autonomous sending without owner approval.

## P0 — Foundational truth

### P0.1 Canonical commerce event, reconciliation, and coverage

**Problem**
Nestly can be correct over the sales entered into Nestly without knowing whether it represents total merchant activity.

**Current evidence**
Authoritative ledgers and idempotent RPCs exist in v11b/v51, but no direct POS reconciliation was found; anonymous and external sales are incomplete. Multi-retail inventory deduction is explicitly deferred in `db/migrations/20260723_frenly_v51_sale_line_items.sql:21-37`.

**Owner benefit**
Owners know what percentage of business revenue Nestly can explain and can trust totals before acting.

**Expected commercial impact**
Prevents bad recommendations and creates the foundation for proving subscription value.

**Data dependency**
Source transaction ID, event time, line items, amounts, tender, status, refunds, business/outlet, customer when known.

**Engineering scope**

- **Database:** Canonical event envelope; source/event uniqueness; partial-refund allocation; revenue/itemization/identity coverage views; quarantine/conflict table; effective timezone/currency.
- **Backend:** One reconciled ingestion adapter or import contract; replay handling; reconciliation job/status.
- **UI:** Data Sources & Coverage card: total known sales, identified sales, anonymous sales, itemization, freshness, reconciliation exceptions.
- **Automation:** Scheduled reconciliation and stale-source alerts.
- **Tests:** Duplicate identical/different payload, late/backdated event, full/partial refund, cancelled/voided, anonymous, multi-outlet, timezone boundary, missing line item.
- **Observability:** Ingestion lag, conflicts, coverage, freshness, reconciliation variance.
- **Privacy/permission:** Tenant-scoped source credentials; no raw contact data in logs; finance/admin permissions.

**Effort:** XL
**Dependencies:** None
**Acceptance criteria**

1. Same source event replay cannot change totals.
2. Conflicting replay is quarantined and visible.
3. Partial and full refunds update net sales, points, and attribution exactly once.
4. Owner sees total, identified, anonymous, itemized, and reconciled coverage with as-of time.
5. Seeded SQL tests cover all required edge cases.

**Why P0**
Every growth conclusion depends on complete, correctly timed transactions.

**Risk if implemented too early**
Supporting many POS vendors before the canonical event contract stabilizes will multiply inconsistent adapters. Start with one adapter/import and a public contract.

### P0.2 Canonical customer lifecycle and metric contract

**Problem**
“Returning” currently means two purchases in the selected period, and identified-customer revenue is labelled as total net revenue.

**Current evidence**
`db/migrations/20260726_nestly_v83_customer_intelligence.sql:286-393` creates identified client metrics; `app/index.html:11163-11169` uses unqualified labels.

**Owner benefit**
Owners can distinguish new, existing returning, repeat, reactivated, at-risk, dormant, and churned customers and understand every denominator.

**Expected commercial impact**
Improves targeting and prevents wasting offers on recently active or genuinely new customers.

**Data dependency**
P0.1 coverage, canonical identity, first-ever transaction, interpurchase history.

**Engineering scope**

- **Database:** Versioned metric views/RPCs; first-ever purchase; lifecycle state; customer/business/segment cadence; total-versus-identified metrics.
- **Backend:** Metric schema with formula, window, timezone, as-of, coverage, confidence.
- **UI:** Rename incorrect labels; show formulas and coverage; separate total and customer-linked panels.
- **Automation:** Incremental lifecycle updates plus nightly reconciliation.
- **Tests:** First/second purchase, pre-period return, reactivation, cadence fallback, shared identity, anonymous coverage, zero denominators, branch scope.
- **Observability:** State-change counts, coverage, stale calculations, invalid cadence.
- **Privacy/permission:** Customer-level details limited to authorized staff; aggregate small-cell suppression where appropriate.

**Effort:** L
**Dependencies:** P0.1
**Acceptance criteria**

1. All owner-facing metrics return formula metadata and coverage.
2. “Returning” has one documented meaning and differs from repeat-in-period/reactivated.
3. No zero-denominator ratio renders as 0%.
4. At-risk/churn uses versioned cadence and suppresses when no defensible fallback exists.
5. Numeric SQL fixtures prove totals across refunds, branches, boundaries, and empty states.

**Why P0**
The NBA target depends on customer state correctness.

**Risk if implemented too early**
Complex ML churn before sufficient history would add false precision. Start with transparent cadence rules.

### P0.3 Audited identity merge and anonymous stitching

**Problem**
Verified linking is safe, but duplicate profiles and anonymous purchases remain disconnected.

**Current evidence**
v81 fails closed on ambiguity but provides no complete merge/stitch workflow.

**Owner benefit**
Customer value and frequency reflect the full known relationship without unsafe guesses.

**Expected commercial impact**
Increases addressable and measurable customer revenue while reducing duplicate outreach.

**Data dependency**
Verified contact proof, transaction source, customer aliases, consent precedence.

**Engineering scope**

- **Database:** Merge proposal/completion/reversal events; aliases; canonical customer ID; provenance; consent conflict policy.
- **Backend:** Candidate scoring only for preview; privileged deterministic merge action; no automatic ambiguous merge.
- **UI:** Duplicate review and anonymous-claim preview with before/after history.
- **Automation:** Safe candidate queue, never automatic completion.
- **Tests:** Shared phone, multiple phones, conflicting consent, cross-business denial, merge replay, reversal, points/reward reconciliation.
- **Observability:** Proposed/approved/rejected/reversed merges and affected value.
- **Privacy/permission:** Owner/admin only; exact tenant; immutable audit; data-request/export compatibility.

**Effort:** L
**Dependencies:** P0.1 event provenance
**Acceptance criteria**

1. Cross-business merge is impossible.
2. Ambiguous contact never auto-merges.
3. History, points, rewards, and consent remain auditable and non-duplicated.
4. Merge replay is idempotent.
5. Coverage updates after approved stitch.

**Why P0**
Customer targeting and value are unreliable without canonical history.

**Risk if implemented too early**
Aggressive fuzzy matching can create a privacy breach. Keep human approval and verified proof.

## P1 — First closed growth loop

### P1.1 Server-authoritative opportunity and recommendation object

**Problem**
Current guidance is fragmented across analytics, configuration drafts, and client-side playbook rules.

**Current evidence**
v35/v44 and `app/grow-recommender.js` contain deterministic suggestions, but no canonical ranked recommendation with evidence/outcome lifecycle exists.

**Owner benefit**
One clear answer to “Who should I act on, why now, and what is it worth?”

**Expected commercial impact**
Directly reduces decision time and focuses incentives on the highest plausible revenue recovery.

**Data dependency**
P0.1–P0.3.

**Engineering scope**

- **Database:** Recommendation/evidence/decision tables; dedupe/expiry; opportunity range; confidence; suppression reason.
- **Backend:** One lapsed-high-value segment; conservative revenue range; cost cap; exclusions; top-one ranking.
- **UI:** Daily briefing card with finding, evidence, impact range, confidence, preview, dismiss, approve.
- **Automation:** Recompute after material event/nightly; expire stale recommendation.
- **Tests:** Cold start, small sample, recent purchase, no consent, duplicate recommendation, changed evidence.
- **Observability:** Generated/presented/accepted/dismissed/expired rates and latency.
- **Privacy/permission:** Aggregates by default; authorized preview of individuals.

**Effort:** L
**Dependencies:** All P0
**Acceptance criteria**

1. Recommendation includes every required contract field.
2. Audience is server-reproducible and matches preview.
3. No recommendation appears below confidence/coverage threshold.
4. Expected figures are deterministic and range-based.
5. Owner can see why each inclusion/exclusion occurred.

**Why P1**
This creates the product's decision layer.

**Risk if implemented too early**
Many recommendation types would hide basic correctness defects. Ship one.

### P1.2 One-channel guarded campaign executor

**Problem**
Manual WhatsApp/contact workflow cannot prove send/delivery and makes “Offers sent” false.

**Current evidence**
`app/index.html:8217-8262` performs manual contact and records issued offers; provider lifecycle is absent.

**Owner benefit**
Preview and approve once; Nestly safely handles the rest and shows failures.

**Expected commercial impact**
Higher execution rate and lower owner effort; establishes exposure evidence.

**Data dependency**
P1.1 recommendation, consent, verified contact, message provider.

**Engineering scope**

- **Database:** Message lifecycle, provider IDs, retry count, quiet hours, frequency cap, suppression audit, cost.
- **Backend:** Queue/executor/callback verifier; consent recheck; idempotent retry; cancellation.
- **UI:** Audience/exclusion preview, message/offer preview, approve, live status, cancel.
- **Automation:** Queue, retry policy, callback handling, budget stop.
- **Tests:** Opt-out after schedule, duplicate callback, timeout, retry, cancellation, quiet hours, budget exhaustion.
- **Observability:** Queue lag, send/delivery/failure, provider cost, suppression reasons.
- **Privacy/permission:** Purpose/channel consent; least-privilege provider secrets; owner approval.

**Effort:** L
**Dependencies:** P1.1
**Acceptance criteria**

1. No send occurs without current consent.
2. Same campaign/customer/channel cannot send twice.
3. Provider state, not UI intent, drives sent/delivered labels.
4. Failure and retry are owner-visible.
5. Frequency cap, quiet hours, cancellation, and cost cap are enforced server-side.

**Why P1**
Without exposure evidence there is no credible attribution.

**Risk if implemented too early**
Multiple channels multiply consent/provider complexity. Support one.

### P1.3 Single-use entitlement and transaction linkage

**Problem**
Campaign offer records, reward grants, redemption, and purchases are not one complete lineage.

**Current evidence**
v50 issues treatment-only offers, while reward/QR modules exist separately.

**Owner benefit**
Staff can redeem safely, customers cannot double-spend, and every associated purchase is traceable.

**Expected commercial impact**
Reduces fraud and measures offer economics.

**Data dependency**
P1.1 campaign/recommendation, P1.2 delivery, authoritative transactions.

**Engineering scope**

- **Database:** Entitlement with campaign/recommendation/customer/rule/expiry/cost; redemption and transaction FKs; reversal.
- **Backend:** QR/token prepare-scan-confirm; idempotent single use; min spend/product/outlet restrictions.
- **UI:** Customer reward card/QR; merchant scan and explicit confirmation; clear used/expired state.
- **Automation:** Expiry and liability reconciliation.
- **Tests:** Replay, concurrent scans, wrong tenant/outlet/product, refund/reversal, expiry boundary.
- **Observability:** Issued/claimed/redeemed/expired/reversed and fraud denials.
- **Privacy/permission:** Opaque short-lived QR; staff permission; no customer PII in token.

**Effort:** M
**Dependencies:** P1.1, P1.2
**Acceptance criteria**

1. Exactly one successful redemption under concurrency.
2. Redemption links to the completed transaction and campaign.
3. Refund/reversal updates entitlement and outcome by policy.
4. Restrictions and expiry are server-enforced.
5. Cost is recorded.

**Why P1**
It connects action to commerce.

**Risk if implemented too early**
Do not introduce generalized stored value; use one narrow entitlement.

### P1.4 Automatic holdout outcome and incremental-revenue evaluation

**Problem**
The v50 experimental core relies on manual return recording and permits 0% holdout.

**Current evidence**
Deterministic holdout and lift RPCs exist in v50; `app/index.html:8178` manually invokes return recording.

**Owner benefit**
Owner sees a defensible “estimated additional revenue” result without maintaining a spreadsheet.

**Expected commercial impact**
Creates the first proof that Nestly may pay for itself.

**Data dependency**
P0 transaction coverage, P1.2 exposure, P1.3 transaction linkage.

**Engineering scope**

- **Database:** Automatic eligible-outcome materialization; experiment validity; arm balance; overlap exclusion; confidence interval; provisional/final result.
- **Backend:** Event-driven outcome link; intent-to-treat evaluator; invalidation.
- **UI:** Treatment/holdout, delivered, purchasers, associated revenue, incremental range, confidence, “inconclusive” state.
- **Automation:** Evaluate continuously; finalize after window.
- **Tests:** Exposure/no purchase, purchase/no redemption, holdout purchase, overlapping campaign exclusion, small sample, late refund.
- **Observability:** Experiment validity, arm sizes, missing delivery, evaluation lag.
- **Privacy/permission:** Aggregated results; small-cell suppression.

**Effort:** L
**Dependencies:** P1.2, P1.3
**Acceptance criteria**

1. Return outcomes update automatically from authoritative transaction events.
2. Minimum holdout/sample policy is enforced or causal claims are suppressed.
3. Invalid overlap/exposure/refund conditions are visible.
4. Result is a range with method, window, and confidence.
5. No result is labelled profit.

**Why P1**
This closes MEASURE.

**Risk if implemented too early**
Sophisticated causal ML is unnecessary. Start with transparent randomized intent-to-treat.

### P1.5 Owner-visible result and recommendation calibration

**Problem**
No closed recommendation decision/outcome history improves future estimates.

**Current evidence**
v50 results exist, but no recommendation feedback/calibration loop was found.

**Owner benefit**
Daily screen answers “Did it work, what did it cost, and what will Nestly do differently?”

**Expected commercial impact**
Builds trust and gradually calibrates opportunity estimates.

**Data dependency**
P1.1–P1.4.

**Engineering scope**

- **Database:** Recommendation decisions, dismissal reasons, result snapshot, calibration error, policy version.
- **Backend:** Compare predicted range to observed estimate; adjust only bounded rule parameters after adequate history.
- **UI:** Completed-action result card and recommendation history.
- **Automation:** Finalize/calibrate after attribution window.
- **Tests:** Accepted/dismissed/expired/failed/inconclusive/won, model-policy versioning.
- **Observability:** Prediction calibration, acceptance, execution, measured-win rates.
- **Privacy/permission:** Aggregate results; immutable audit.

**Effort:** M
**Dependencies:** P1.4
**Acceptance criteria**

1. Every recommendation has a terminal or current state.
2. Owner can see prediction, action, cost, observed result, and confidence.
3. Inconclusive results do not count as wins.
4. Policy changes are versioned and reversible.
5. Calibration uses structured outcomes, not generated prose.

**Why P1**
This closes LEARN at a safe initial level.

**Risk if implemented too early**
Do not let a few campaigns autonomously change business economics.

## P2 — Expansion after the loop is trusted

### P2.1 Margin and campaign-profit contract

**Problem**
Nestly cannot calculate incremental gross profit or campaign ROI.

**Current evidence**
General item/service cost, full discount cost, message cost, and margin are absent.

**Owner benefit**
Know whether higher sales actually created profit.

**Expected commercial impact**
Prevents loss-making discounts and supports subscription value proof.

**Data dependency**
Effective-dated item/service cost; reward/discount/message cost; P1 experiment.

**Engineering scope**

- **Database:** Cost history, contribution margin policy, cost allocations.
- **Backend:** Profit estimator and completeness gate.
- **UI:** Margin coverage, incremental gross-profit range, ROI.
- **Automation:** Missing-cost alerts.
- **Tests:** Cost changes, bundles, partial refunds, zero/negative margin.
- **Observability:** Cost coverage and profit calculation eligibility.
- **Privacy/permission:** Finance-only cost access.

**Effort:** L
**Dependencies:** Completed P1, itemization coverage
**Acceptance criteria:** Profit is unavailable until cost coverage passes; every cost is traceable; seeded numeric tests pass.
**Reason for priority:** Highest commercial upgrade after revenue proof.
**Risk if early:** False profit is more dangerous than no profit.

### P2.2 Deterministic revenue-driver decomposition

**Problem**
Owners see outcomes without quantified “why.”

**Current evidence**
The implemented bridge explains identified-customer count, purchase frequency,
average transaction value, anonymous revenue, and rounding residual. It also
reports transaction and revenue itemization coverage. It deliberately does not
claim product price/volume/mix attribution until itemization is complete and a
versioned product taxonomy exists.

**Owner benefit**
Understand the cause before acting.

**Expected commercial impact**
Improves action selection and reduces unnecessary discounts.

**Data dependency**
Reconciled transaction and item coverage.

**Engineering scope:** Server decomposition, residual, coverage; daily briefing explanation; no LLM authority.
**Database:** Comparison snapshots and driver contributions.
**Backend:** Deterministic calculations.
**UI:** Top three quantified drivers.
**Automation:** Daily recompute.
**Tests:** Customer count, frequency, AOV, refund-period boundary, branch,
anonymous coverage, itemization coverage, and an explicit `not_claimed`
price/volume/mix state.
**Observability:** Residual and unavailable-driver rate.
**Privacy/permission:** Aggregate small samples.
**Effort:** L
**Dependencies:** P0.1, P0.2
**Acceptance criteria:** The supported contributions reconcile to total change
within rounding; unavailable drivers and line-level price/volume/mix limitations
are explicit. No line-level causal explanation is emitted without its required
coverage and taxonomy.
**Reason for priority:** Moves from reporting to diagnosis.
**Risk if early:** Bad line-item coverage creates invented explanations.

### P2.3 Additional closed-loop playbooks

**Problem**
One bring-back loop does not cover birthdays, rebooking, renewals, referrals, or slow periods.

**Current evidence**
Several modules and scheduling foundations exist but not at verified closed-loop maturity.

**Owner benefit**
More revenue opportunities without learning a campaign builder.

**Expected commercial impact**
Expands measured growth surface.

**Data dependency**
Reusable P1 contracts and sector-specific events.

**Engineering scope:** Template policies for rebooking, membership renewal, reward expiry, referral, and slow period.
**Database:** Recommendation type/policy version.
**Backend:** Eligibility and cost guards.
**UI:** Same one-screen approve/result pattern.
**Automation:** Reusable executor.
**Tests:** Type-specific eligibility, consent, expiry, holdout feasibility.
**Observability:** Results per playbook.
**Privacy/permission:** Purpose-specific consent and sensitive-service restrictions.
**Effort:** XL
**Dependencies:** Proven P1 loop
**Acceptance criteria:** Each new playbook passes the same lineage/attribution contract and cannot bypass consent.
**Reason for priority:** Reuse proven infrastructure.
**Risk if early:** More incomplete modules increase complexity.

### P2.4 Governed language assistant

**Problem**
Deterministic findings need concise owner/customer copy, but an LLM must not invent figures or advice.

**Current evidence**
No production LLM integration was found.

**Owner benefit**
Clear, localized explanation and campaign wording.

**Expected commercial impact**
Faster approval and better communication without compromising calculations.

**Data dependency**
Structured P1 recommendation and P2.2 driver output.

**Engineering scope:** Schema-constrained explanation/copy only; deterministic figures locked.
**Database:** Prompt/model/version/output audit and owner edits.
**Backend:** PII minimization, validation, rate/cost limits, fallbacks.
**UI:** “Improve wording” with factual preview; never “AI calculated.”
**Automation:** None without approval.
**Tests:** Hallucinated number rejection, malformed output, prompt injection, localization.
**Observability:** Cost, latency, rejection, owner edit rate.
**Privacy/permission:** Minimize PII; tenant isolation; vendor terms.
**Effort:** M
**Dependencies:** Structured truth layer
**Acceptance criteria:** Model cannot alter figures/eligibility; outputs are versioned and schema-valid; deterministic fallback exists.
**Reason for priority:** Language is useful only after truth exists.
**Risk if early:** Fluent false advice damages trust.

### P2.5 Sector-specific cadence and opportunity policies

**Problem**
Hawkers, salons, clinics, gyms, and tuition centres have different visit cycles and actions.

**Current evidence**
Current generic thresholds include hardcoded lapse concepts; service modules include appointments/packages but no unified sector policy engine.

**Owner benefit**
Recommendations fit the business model.

**Expected commercial impact**
Higher relevance and less campaign fatigue.

**Data dependency**
P0 lifecycle, sufficient per-sector outcomes, service/appointment/package events.

**Engineering scope:** Versioned sector policy registry with business overrides and evidence.
**Database:** Policy version/effective dates.
**Backend:** Sector-specific eligibility/cold start.
**UI:** Plain-language recommended defaults and owner override.
**Automation:** Policy evaluation.
**Tests:** Hawker, salon, clinic, gym, tuition fixtures; cadence boundaries.
**Observability:** Performance/calibration by sector.
**Privacy/permission:** Sensitive-sector restrictions.
**Effort:** L
**Dependencies:** Sufficient measured P1 outcomes
**Acceptance criteria:** Every rule identifies sector, evidence, fallback, and suppression; no universal churn number.
**Reason for priority:** Supports expansion without generic advice.
**Risk if early:** Small samples create overfit defaults.

## Recommended delivery order

```text
P0.1 → P0.2 → P0.3
                 ↓
P1.1 → P1.2 → P1.3 → P1.4 → P1.5
                                      ↓
P2.1 / P2.2 → P2.3 → P2.4 / P2.5
```

## Exit criteria for calling Nestly a closed-loop growth product

Nestly should not use that classification until:

1. Sales coverage and freshness are visible and reconciled.
2. Customer lifecycle definitions are canonical and tested.
3. A recommendation is ranked, evidence-backed, cost-bounded, and confidence-gated.
4. Consent-aware execution records provider delivery state.
5. A single-use offer links to the outcome transaction.
6. Holdout or another defensible method is valid and automatic.
7. Result language distinguishes associated, incremental revenue, and incremental gross profit.
8. Owner sees prediction, cost, result, and confidence.
9. The system stores acceptance/dismissal/outcome and uses it for bounded calibration.
10. Database and browser acceptance tests verify the complete loop.
