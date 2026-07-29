# Retention Intelligence Audit

## Bottom line

Nestly has a technically credible measurement core but an incomplete causal chain.

The deterministic treatment/holdout assignment and reversal-aware return/revenue calculations are real. The system is not merely a points database. However, it is not yet a trustworthy automated growth system because it cannot prove treatment exposure and does not consistently model net contribution.

## Customer model coverage

| Attribute | Status | Notes |
| --- | --- | --- |
| First/most recent visit | Implemented | Derived from Nestly-recorded transactions/visits |
| Visit count | Implemented | Used in intelligence/cohort logic |
| Purchase frequency/cadence | Implemented/heuristic | Supports overdue/declining customers |
| Average order value | Implemented | Based on recorded revenue |
| Total spend | Implemented | Reversal-aware read models |
| Gross profit contribution | Missing/partial | Revenue is stronger than margin/COGS |
| Preferred outlet | Implemented/derivable | Branch data exists |
| Preferred product/category | Partial | Line items exist; workflow personalisation is limited |
| Preferred visit time | Partial | Transaction timestamps exist; limited action use |
| Reward history | Implemented | Ledgers/redemptions |
| Campaign history | Partial | Grants/results exist; exposure missing |
| Referral activity | Implemented/partial | Programme/referral records exist |
| Review activity | Partial | Link/prompt; completion not verified |
| Lifecycle stage | Implemented/heuristic | Lapsed/regular/value cohorts |
| Predicted churn risk | Partial | Cadence/inactivity heuristics, not validated model |
| Predicted next purchase | Partial | Moving forecast/cadence logic, limited proof |
| Discount sensitivity | Missing | No reliable experiment/history model |
| CLV | Partial | Historical/projected revenue, not complete margin CLV |
| VIP status | Implemented/heuristic | Value/frequency grouping |
| Consent state | Implemented | Events/preferences/opt-out |
| Communication fatigue | Structure partial | No live delivery history |
| Household/duplicate risk | Missing/weak | No mature merge/household graph |

## Data quality dependency

Every intelligence result depends on transaction completeness:

```text
manual capture rate falls
→ last visit becomes wrong
→ cadence/churn classification becomes wrong
→ audience becomes wrong
→ attribution denominator becomes wrong
→ owner trust falls
```

The most important intelligence investment is therefore not another model. It is reliable transaction ingestion and data-quality confidence.

Every recommendation/report should display:

- automated/manual transaction coverage;
- last successful sync;
- unmatched/duplicate identity count;
- branch completeness;
- sample size;
- confidence/eligibility.

## Segmentation and churn detection

Current system supports:

- lapsed-day threshold;
- minimum past visits;
- value/frequency/returning cohorts;
- branch/date filtering;
- cadence/overdue reasoning;
- action/result exports through platform intelligence.

It can credibly say:

> “34 customers recorded at least three visits and have no Nestly-recorded visit in 30 days.”

It cannot yet credibly say:

> “These customers will churn”

without labelled outcomes, validation and calibrated performance.

Use “overdue/inactive under this rule,” not predictive language, until precision/recall and business-specific cadence are measured.

## Recommendation engine

Recommendation drafts and local unified Grow setup are useful. Recommendations should become explicit decision objects:

```text
observation
→ eligibility and exclusions
→ expected customer value
→ expected merchant cost
→ suggested treatment and holdout
→ reason and confidence
→ owner/consultant approval
→ actual execution
→ verified outcome
```

Current gap: detection and grant creation are better implemented than real execution.

## Campaign automation

Current classification:

| Stage | Status |
| --- | --- |
| Detect audience | Implemented |
| Allocate treatment/holdout | Implemented |
| Record budget/expected cost | Implemented |
| Grant/record offer | Implemented, but entitlement semantics need confirmation |
| Draft message | Guided/manual |
| Enforce consent against provider | Not verified |
| Queue real message | Missing |
| Deliver | Missing |
| Receive provider receipt | Missing |
| Record open/click | Missing |
| Suppress duplicate/fatigue | Not end-to-end verified |
| Record return | Implemented if transaction is captured |
| Calculate lift | Implemented but exposure-invalid |
| Stop poor campaign | Not automatic |

## Attribution and incrementality

### Strong

- deterministic holdout;
- immutable audience membership;
- treatment-only grants;
- defined attribution windows;
- reversal-aware return/revenue;
- incremental-return and revenue point estimates;
- replay-safe campaign operations.

### Invalidating gaps

1. `campaign activated` is not `customer exposed`.
2. Manual owner contact is not observed.
3. A grant is not a delivered message.
4. Pre-contact returns can fall in the measurement period.
5. No confidence interval/significance/minimum sample is shown.
6. Reward cost is incomplete for manual/free items.
7. Messaging cost and subscription cost are not included in net contribution.

Required result states:

- `setup`;
- `delivery unknown`;
- `insufficient exposure`;
- `insufficient sample`;
- `directional observation`;
- `statistically supported result`;
- `inconclusive`;
- `negative contribution`.

Never collapse these into a universal “brought back” badge.

## Profitability measurement

Required formula:

```text
net incremental contribution
= incremental revenue
 × gross-margin rate (or item contribution)
 - redeemed reward COGS
 - messaging/provider cost
 - payment/refund leakage attributable to campaign
```

Also show:

- contribution per delivered customer;
- contribution per S$1 reward cost;
- contribution per S$1 total campaign cost;
- subscription payback;
- uncertainty range.

The current system is closer to incremental revenue than incremental profit.

## Explainability

Every customer/action should expose an owner-safe reason:

- “visited 6 times”;
- “usual cadence 14 days”;
- “last visit 35 days ago”;
- “marketing consent active”;
- “not contacted in 30 days”;
- “expected reward cost S$X”;
- “excluded from holdout contact.”

Do not expose sensitive inference to frontline staff or include unnecessary profiling in customer messages.

## Intelligence feature access

The intelligence RPC/report/export is built and platform users/consultants can use it. Business owners are intentionally blocked from the module.

Recommended product model:

- owner receives a concise monthly result summary;
- consultant receives full cohort/detail and action tools;
- premium plan previews 2–3 insights with “review with your Nestly consultant”;
- every claim links to definitions, data coverage and evidence.

This preserves consultative value while preventing a hidden-feature dead end.

## Defensible advantage after closure

Once Nestly connects real exposure and transaction ingestion, its combination of:

- merchant-confirmed redemption;
- immutable programme/ledger history;
- verified treatment delivery;
- holdouts;
- reversal-aware net contribution;
- branch-aware benchmarking;

would be meaningfully harder for a basic POS loyalty add-on to copy.

