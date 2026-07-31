# Nestly Canonical Metric and Event Contract

**Date:** 2026-07-30
**Purpose:** Define the data and metric contract required for trustworthy revenue intelligence and a measurable next-best-action loop.
**Status:** Audit recommendation only; no implementation was performed.

## Contract principles

1. Financial totals are calculated in Postgres/server code, never in free-form AI output.
2. Every business event has a stable source identity, tenant, occurred time, received time, status, authority, and idempotency key.
3. Historical facts are append-only. Corrections use reversal, refund, void, supersession, or merge events.
4. Business-day calculations use an authoritative IANA business/outlet timezone.
5. Money is integer minor units plus ISO currency. Cross-currency totals are forbidden without a versioned FX source.
6. “Total business” and “identified customer” metrics are distinct and always show coverage.
7. Associated revenue, redeemed revenue, incremental revenue, and incremental gross profit are distinct.
8. Recommendations are versioned decision objects, not transient UI text.
9. Delivery and outcomes are events with state; a success toast is not evidence of delivery.
10. Cold-start or low-confidence results suppress claims rather than fabricate precision.

## Current data availability

### Data Nestly already has

- Business, branch/outlet, staff, customer/client, verified customer identity and relationship links.
- Services and products.
- Appointments/bookings and visit-related status.
- Sales, itemized sales for authoritative cart paths, payments, reversals, points, rewards, packages, memberships, and gift-card/stored-value foundations.
- Campaign, audience snapshot, deterministic treatment/holdout assignment, issued offer/grant, return evidence, and result RPC structure.
- Branch/firm filters, server-side customer intelligence, and conservative forecast sufficiency gates.
- Consent/legal-manifest structures and customer notification foundations.

### Data Nestly partially has

- Complete transaction line items: custom-amount/manual sales and external merchant sales can lack item detail.
- Customer identity: safe verified links exist, but duplicate and anonymous histories cannot be completely merged.
- Refunds: full reversal support is stronger than general partial-refund allocation.
- Customer consent: stored in parts of the platform; end-to-end promotional execution enforcement is unverified.
- Product inventory: exists, but a multi-retail cart can skip deduction.
- Campaign exposure: offer issuance exists, provider delivery/exposure does not.
- Offer cost: database fields exist in parts of the campaign model; UI/executor does not consistently populate full cost.
- Forecast: method/gates exist, but data coverage is not reconciled to external sales.
- Staff attribution: present where a sale/appointment records staff, but not universally complete.

### Data Nestly does not have authoritatively

- Reconciled total merchant sales coverage.
- General partial-refund line/payment allocation.
- General product/service COGS and gross margin.
- Explicit per-line discount, tax, service charge, tip, and promotion allocation.
- Product category taxonomy suitable for analysis.
- Audited anonymous-to-identified stitching.
- Reliable acquisition source and acquisition cost.
- Provider message queued/sent/delivered/failed/opened/clicked lifecycle for growth campaigns.
- Message cost, full discount cost, and campaign operating cost.
- Complaint/service-failure signal.
- Business-specific and customer-specific expected cadence models.
- Recommendation object, ranking, decision history, outcome, and feedback.
- Experiment uncertainty/minimum-sample calculation and overlap policy.
- External weather, footfall, local event, competitor, or price-elasticity data.

### Data requiring external integrations

- POS/e-commerce orders, line items, discounts, taxes, refunds, and tender reconciliation.
- Payment-provider settlement and chargeback events.
- Messaging-provider delivery callbacks and costs.
- Optional accounting cost/margin feeds.
- Optional weather, holiday/event, and footfall feeds.
- Optional ad-platform or acquisition-channel spend/click/conversion data.

### Data that must not be inferred

- Weather impact without weather data and an identified comparison method.
- Staff causation when staff attribution is missing or non-exclusive.
- Product loyalty without reliable line-item coverage.
- Profit, profit LTV, or campaign profit without margin and all material costs.
- Customer identity from an ambiguous shared phone/email.
- Campaign causation from a post-message purchase alone.
- A business-specific churn threshold from one universal number.
- Price elasticity or safe price increases from transaction history alone.

## Canonical entity relationships

```text
business
  ├─ outlet
  ├─ staff_membership
  ├─ customer_profile
  │    ├─ customer_identity_alias
  │    ├─ customer_consent
  │    └─ loyalty_account
  ├─ catalog_item
  │    ├─ catalog_variant
  │    ├─ category
  │    └─ cost_history
  ├─ transaction
  │    ├─ transaction_line
  │    ├─ payment
  │    ├─ refund
  │    └─ loyalty_operation
  ├─ recommendation
  │    ├─ recommendation_evidence
  │    ├─ recommendation_decision
  │    └─ campaign
  │         ├─ audience_member
  │         ├─ message
  │         ├─ offer_entitlement
  │         ├─ exposure
  │         ├─ redemption
  │         └─ attributed_outcome
  └─ experiment
       ├─ assignment
       └─ result
```

Every child carries `business_id`. Outlet-scoped rows also carry `outlet_id`. Composite foreign keys or equivalent server validation must prevent a child from referencing another tenant's object.

## Canonical event envelope

Every mutable-domain occurrence should be representable as an immutable event:

| Field | Contract |
|---|---|
| `event_id` | UUID generated by authoritative server |
| `event_type` | Versioned string, e.g. `transaction.completed.v1` |
| `schema_version` | Positive integer |
| `business_id` | Required tenant |
| `outlet_id` | Required when operationally scoped |
| `subject_type`, `subject_id` | Stable aggregate reference |
| `source_system` | `nestly`, POS/provider identifier, import identifier |
| `source_event_id` | Required for external/replayable source |
| `idempotency_key` | Unique within business/source/event type |
| `occurred_at` | Source business event time, timestamptz |
| `received_at` | Server receipt time |
| `recorded_at` | Persistence time |
| `business_date` | Derived from occurred time and versioned outlet timezone |
| `currency` | ISO 4217 when monetary |
| `amount_minor` | Signed integer minor units when monetary |
| `actor_type`, `actor_id` | Customer, staff, system, import, provider |
| `causation_id` | Immediate causing event |
| `correlation_id` | End-to-end workflow identifier |
| `supersedes_event_id` | Correction/supersession relationship |
| `payload` | Schema-validated attributes only |
| `payload_hash` | Detect same source ID with altered payload |

Unique constraint: `(business_id, source_system, source_event_id, event_type)` where an external source ID exists. A repeated identical payload is a no-op/replay response. A repeated ID with a different hash is quarantined for reconciliation.

## Required event catalogue

### Commerce

```text
transaction.created.v1
transaction.completed.v1
transaction.cancelled.v1
transaction.voided.v1
transaction.corrected.v1
transaction_line.recorded.v1
payment.authorized.v1
payment.captured.v1
payment.failed.v1
payment.refunded.v1
refund.created.v1
refund.completed.v1
chargeback.opened.v1
chargeback.resolved.v1
```

### Identity and consent

```text
customer.created.v1
customer.identified.v1
customer.alias_added.v1
customer.merge_proposed.v1
customer.merge_completed.v1
customer.merge_reversed.v1
consent.granted.v1
consent.withdrawn.v1
contact.verified.v1
```

### Loyalty

```text
points.earned.v1
points.reversed.v1
points.expired.v1
reward.issued.v1
reward.claimed.v1
reward.redeemed.v1
reward.reversal.v1
voucher.issued.v1
voucher.redeemed.v1
voucher.expired.v1
package.sold.v1
package.session_used.v1
package.session_restored.v1
```

### Recommendation/campaign

```text
recommendation.generated.v1
recommendation.suppressed.v1
recommendation.viewed.v1
recommendation.accepted.v1
recommendation.dismissed.v1
recommendation.expired.v1
campaign.created.v1
campaign.approved.v1
campaign.activated.v1
audience.eligible.v1
audience.excluded.v1
experiment.assigned.v1
message.queued.v1
message.sent.v1
message.delivered.v1
message.failed.v1
message.opened.v1
message.clicked.v1
offer.issued.v1
offer.claimed.v1
offer.redeemed.v1
campaign.cancelled.v1
campaign.completed.v1
outcome.observed.v1
experiment.evaluated.v1
recommendation.calibrated.v1
```

## Transaction status and financial eligibility

Canonical status progression:

```text
draft → pending → completed
draft/pending → cancelled
completed → partially_refunded
completed/partially_refunded → fully_refunded
completed → voided only through an explicit authoritative correction policy
```

Never delete a completed transaction. A refund is a separately identified financial event allocated to payment and, where possible, transaction lines.

### Revenue fields

For each transaction:

```text
gross_item_amount
= Σ(quantity × unit_list_price_minor)

discount_amount
= Σ(line_discount_minor) + order_discount_minor

net_before_tax
= gross_item_amount - discount_amount

tax_amount
= Σ(line_tax_minor) + order_tax_minor

service_charge_amount
= explicit service charge

tip_amount
= explicit tip

customer_charge
= net_before_tax + tax_amount + service_charge_amount + tip_amount
```

The business must configure whether reported operating revenue includes tax and service charge. Nestly should expose both a standard net-sales metric and a clearly labelled cash/charge metric.

### Refund-adjusted net sales

```text
eligible completed net_before_tax
- completed refunds allocated to net_before_tax
```

Exclude cancelled/voided transactions. Tips, tax, gift-card top-ups, stored-value top-ups, and liability issuance are excluded from net sales unless a separate accounting policy explicitly recognizes them.

## Timezone and currency rules

1. `business.default_timezone` and each `outlet.timezone` are IANA names.
2. `business_date` derives from `occurred_at AT TIME ZONE outlet.timezone`, never from browser locale.
3. Reporting windows are half-open: `[start_at, end_at)`.
4. A backdated event is included according to `occurred_at`, while freshness/reconciliation reports also show `received_at`.
5. A timezone change creates a versioned effective-dated setting; historical business dates do not silently move.
6. All stored money uses integer minor units and ISO currency.
7. No multi-currency aggregate is shown unless grouped by currency or converted by a versioned FX rate with source and time.

## Customer identity rules

1. A platform person and a business customer record are distinct.
2. Verified email/phone can propose links; ambiguous collisions never auto-merge.
3. A merge requires:
   - same business,
   - privileged actor,
   - a preview of conflicting names/contacts/consents,
   - immutable merge event,
   - alias preservation,
   - transaction/loyalty lineage preservation,
   - reversible correction before external side effects.
4. Consent is purpose-, channel-, brand-, and version-specific. Withdrawal is effective immediately.
5. An anonymous sale receives an anonymous session/token where possible. Later stitching requires customer proof and an audited server action.
6. Identity coverage is always reported:

```text
identified_transaction_coverage
= eligible completed transactions linked to customer
 / all eligible completed transactions

identified_revenue_coverage
= identified refund-adjusted net sales
 / total refund-adjusted net sales
```

## Customer lifecycle and cadence rules

### First-ever purchase

Earliest eligible `transaction.completed` event for the canonical merged customer within the business. Refunds that fully eliminate the transaction should not count as a retained first purchase.

### New customer in period

Customer whose first-ever eligible purchase occurs in `[period_start, period_end)`.

### Existing returning customer

Customer with at least one eligible purchase before `period_start` and at least one in the period.

### Repeat purchaser in period

Customer with at least two eligible purchases in the period. This must not be labelled simply “returning.”

### Reactivated customer

Customer with a purchase in the period after exceeding their effective lapse threshold before that purchase.

### Active customer

Customer whose days since last eligible purchase are less than or equal to the effective active threshold.

### Dormant/at-risk/churned

Do not use one universal day count. Determine:

```text
customer_expected_interval
= robust median of eligible interpurchase intervals

segment_expected_interval
= robust median for comparable lifecycle/vertical segment

business_fallback_interval
= business-configured or sector-informed default

effective_interval
= customer interval when sufficient observations
   else segment interval when sufficient sample
   else business fallback
```

Recommended initial states:

```text
active: days_since_last <= 1.25 × effective_interval
at_risk: >1.25× and <=2.0×
dormant: >2.0× and <=3.0×
churned: >3.0×
```

These multipliers are configuration policy, not universal truth. Store the policy version and evidence used for each classification. Service sectors need appointment/rebooking cadence and attendance/no-show context.

## Metric dictionary

| Metric | Exact formula | Eligible records | Exclusions | Required dimensions/notes |
|---|---|---|---|---|
| Gross item sales | Σ quantity × list unit price | Completed transaction lines | Cancelled/voided; refunds reported separately | Currency, business date, outlet |
| Net sales | Gross item sales − discounts − completed refund allocation | Completed/refund events | Tax, tips, liability issuance by default | State accounting policy |
| Customer charge | Net before tax + tax + service charge + tip | Completed captures | Failed/voided | Not called revenue |
| Cash collected | Captured payments − payment refunds for selected tender types | Captured/refunded payments | Gift/stored-value liability issuance separated | Tender and settlement date |
| Completed transactions | Count distinct completed transaction IDs with non-fully-refunded eligible value according to policy | Completed | Cancelled/voided | Publish refund treatment |
| Average order value | Refund-adjusted net sales / completed transactions | Same numerator/denominator scope | Zero denominator → null, not 0 | Show completeness |
| Items per order | Σ eligible quantity / transactions with reliable line items | Completed itemized transactions | Non-itemized/custom amount | Show itemization coverage |
| Unique customers | Count canonical identified customers with eligible transaction | Identified completed | Anonymous | Show identity coverage |
| New customers | Count customers whose first-ever transaction is in period | Canonical history | Fully eliminated first transaction | Business scope |
| Existing returning customers | Pre-period transaction and in-period transaction | Canonical history | Anonymous | Separate from repeat-in-period |
| Repeat purchasers | 2+ eligible transactions in period | Canonical history | Anonymous | Explicit label |
| Repeat customer rate | Existing returning customers / transacting customers who existed before period | Identified customers | New customers from denominator | Publish denominator |
| Repeat revenue | Net sales from customers who had an earlier eligible transaction before each counted sale | Identified sales | Anonymous | Event-time determination |
| Visit frequency | Eligible visits / active observation time, plus median interpurchase interval | Identified customers | Cancelled/no-show unless specified | Service visit policy |
| Recency | Business days since last eligible transaction/visit | Identified | None | As-of timestamp |
| Monetary value | Refund-adjusted net sales in versioned window | Identified | Anonymous | RFM window |
| Lifetime revenue | All-time refund-adjusted identified net sales | Canonical merged identity | Anonymous/unstitched | Never call profit LTV |
| Active/dormant/at-risk/churned | Cadence state rules above | Identified customers with sufficient/fallback cadence | Suppress when no valid fallback | Policy version |
| Reactivated customers | Purchase after crossing lapse threshold | Identified | None | Store reactivation event |
| Revenue by outlet | Net sales grouped by outlet | Completed/refunds | Cross-outlet unassigned | Coverage |
| Revenue by product/category | Net sales allocated to lines and taxonomy | Itemized sales | Unitemized amount | Itemization coverage |
| Revenue by hour/weekday | Net sales grouped by local business time | Completed/refunds | Unknown timezone | Outlet timezone |
| Reward issuance | Count/value of issued entitlements | Issued | Reversed issuance | Rule version |
| Reward redemption rate | Unique redeemed entitlements / eligible issued entitlements | Issued during cohort window | Reversed/test | Cohort and maturity window |
| Breakage | Mature expired unused value / mature issued value | Entitlements past expiry | Still-active cohort | Liability policy |
| Reward liability | Unredeemed valid monetary-equivalent entitlement under accounting policy | Active issued | Redeemed/expired/reversed | Do not guess value |
| Campaign delivery rate | Delivered / attempted supported messages | Provider lifecycle | Holdout, suppressed | Channel |
| Campaign conversion | Purchasers in attribution window / assigned audience | Treatment and holdout separately | Ineligible/suppressed by pre-specified rule | Intent-to-treat primary |
| Associated revenue | Net sales from exposed/eligible customer inside attribution window | Defined association | No causal wording | Overlap flag |
| Incremental conversion lift | treatment conversion − holdout conversion | Randomized comparable arms | Invalid/underpowered experiment | Confidence interval |
| Estimated incremental transactions | lift × treatment assigned population | Valid experiment | Invalid sample | Range |
| Estimated incremental revenue | Incremental transactions × pre-specified relevant AOV, or direct difference-in-means estimator | Valid experiment | Invalid exposure/data | Range and method |
| Incremental gross profit | Incremental revenue × contribution margin − incremental reward/discount/message/other costs | Valid experiment + full cost data | Missing margin/cost | Unavailable until data complete |
| Campaign ROI | Incremental gross profit / incremental campaign cost | Same | Zero/unknown cost | Not revenue/cost ratio |
| Referral conversion | Referred canonical new customers with eligible first transaction / valid referral invitations | Referral lineage | Self/duplicate/fraud | Source lineage |

Empty financial totals may be 0 only when source coverage is known. Ratios with zero denominators are `null`/“Not enough data,” not 0%.

## Revenue-change decomposition

Before any language generation, calculate deterministic contributors:

```text
Revenue change
= transaction-count effect
 + average-order-value effect
 + interaction/residual
```

Then decompose transaction count where coverage allows:

```text
transaction count
→ new customers
→ existing returning customers
→ visit frequency
→ reactivated/lapsed customers
```

Decompose AOV where reliable line items allow:

```text
AOV
→ item count
→ price
→ discount
→ product/category mix
```

Every explanation records periods, coverage, quantified contributions, residual, and unavailable drivers. It says “associated with” unless a causal experiment supports stronger language.

## Campaign event lifecycle

```text
draft
→ approved
→ audience_snapshot_created
→ experiment_assigned
→ scheduled
→ executing
→ completed | cancelled | failed
→ evaluating
→ evaluated
```

Per audience member:

```text
eligible
→ excluded(reason) | holdout | treatment
treatment
→ suppressed(reason) | queued
queued
→ sent | failed
sent
→ delivered | failed | unknown
delivered
→ opened/clicked where supported
→ offer_claimed
→ offer_redeemed
→ outcome_observed
```

Eligibility is snapshotted, but consent and hard suppression are rechecked immediately before queueing. Withdrawal always wins.

Required exclusion reasons include: no consent, invalid contact, recent contact/frequency cap, recent purchase, current complaint/service failure if available, already has equivalent offer, overlapping campaign, budget exhausted, outside quiet hours, no confidence, and owner/staff exclusion.

## Recommendation lifecycle

Required recommendation fields:

```text
recommendation_id
business_id
outlet_id nullable
type and policy_version
generated_at and valid_until
observation_window and comparison_window
target_segment definition
finding and evidence JSON
baseline
opportunity_revenue_range
opportunity_profit_range nullable
confidence_state and assumptions
recommended_action/channel/offer
estimated_offer_cost/message_cost
audience_size
frequency_cap and stop_conditions
success_metric and attribution_window
holdout_policy
status
owner_decision and dismissal_reason
campaign_id
execution_status
outcome_id
calibration_result
```

Lifecycle:

```text
generated
→ suppressed | presented
presented
→ accepted | dismissed | expired
accepted
→ executing → completed | failed | cancelled
completed
→ evaluating → measured | inconclusive
measured/inconclusive
→ calibration recorded
```

Deduplicate by business, recommendation type, target definition, and overlapping valid window. A recommendation expires when new data invalidates its evidence.

## Attribution model

### Primary estimator

Use randomized intent-to-treat when eligible audience size is sufficient:

```text
treatment_rate = treatment purchasers / treatment assigned
holdout_rate = holdout purchasers / holdout assigned
lift = treatment_rate - holdout_rate
```

Prefer direct revenue-per-assigned-customer difference when transaction value is highly variable:

```text
incremental_revenue_per_assigned
= mean(treatment net revenue)
 - mean(holdout net revenue)

estimated_incremental_revenue
= incremental_revenue_per_assigned × treatment assigned
```

Report confidence interval, sample size, delivery coverage, and missing-data coverage. If the test is invalid or underpowered, show “inconclusive,” not zero lift.

### Overlapping campaigns

For v1, use mutual exclusion: a customer may be in only one active measured growth campaign during the attribution window. Later multi-treatment models require substantially more data and are P2.

### Redemption

- Redemption proves an entitlement was used.
- Exposure plus purchase is associated revenue.
- Randomized treatment versus holdout estimates incremental revenue.
- Incremental gross profit additionally requires margin and all incremental costs.

## Cold-start and confidence rules

### Data states

| State | Minimum | Product behaviour |
|---|---|---|
| No data | No eligible transactions | Setup/reconciliation guidance only |
| Capture unverified | Sales exist but coverage unknown | Show operational totals with coverage warning; no NBA |
| Early signal | At least 30 eligible transactions and 4 active weeks | Descriptive metrics; no causal claims |
| Basic intelligence | At least 90 days, 12 active weeks, 30 transactions, adequate identity coverage | Forecast/segments with explicit confidence |
| Experiment eligible | Pre-computed minimum arm size and valid consent pool | Measured campaign allowed |
| Decision grade | Reconciled coverage, valid experiment, adequate sample | Incremental-revenue range |
| Profit grade | Decision grade + cost/margin coverage | Incremental-gross-profit range |

Thresholds must be versioned and validated by observed variance; the existing v83 thresholds are a sensible initial forecast gate, not a universal rule for every metric.

### Confidence states

```text
unavailable
low
moderate
high
```

Confidence derives from data coverage, sample size, recency, variance, identity coverage, experiment validity, and provider delivery coverage. It is never generated by an LLM.

## Data freshness requirements

| Source | Target freshness | Stale behaviour |
|---|---|---|
| Nestly checkout transaction | Visible within 10 seconds | Show pending/retry state |
| POS/payment webhook | Ingest within 2 minutes | Alert/reconcile after 5 minutes |
| Message delivery callback | Within provider SLA, usually minutes | State remains sent/unknown, never delivered |
| Customer lifecycle/RFM | Update within 15 minutes of transaction or nightly full reconciliation | Show as-of time |
| Daily briefing | Rebuilt after prior business day close and material late event | Show calculation time and late-event warning |
| Campaign outcome | Near real time transaction link; finalized after attribution window | Provisional versus final state |
| Cost/margin | Effective-dated at sale time | Missing cost blocks profit metric |

Every owner-facing metric shows `as_of`, source coverage, and calculation window.

## Required observability

- Ingestion lag, duplicate/replay count, payload conflicts, quarantined events.
- Transaction coverage versus reconciled source, itemization coverage, identity coverage.
- RPC latency/error/idempotent replay rates.
- Join funnel and checkout funnel completion.
- Recommendation generated/presented/accepted/dismissed/expired.
- Audience eligible/excluded by reason.
- Message queued/sent/delivered/failed/retried.
- Offer issued/claimed/redeemed/expired/reversed.
- Experiment arm sizes, balance checks, conversion, confidence, invalidation reason.
- Cost and margin coverage.
- Data freshness and stale-source alerts.

No metric should silently fall back to fabricated/demo values in a real tenant.
