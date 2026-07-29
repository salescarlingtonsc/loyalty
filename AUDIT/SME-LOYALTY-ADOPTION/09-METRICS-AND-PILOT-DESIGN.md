# Metrics and Pilot Design

## Pilot objective

Determine whether Nestly can:

1. launch without heavy support;
2. achieve reliable staff/transaction usage;
3. enrol customers with low friction;
4. deliver one consent-aware retention action;
5. produce positive, credible net incremental contribution;
6. retain paying SMEs.

## Cohort

Recommended: **12–18 SMEs**.

- 6–8 salons/spas/nail/barber/pet-grooming firms;
- 6–8 owner-operated cafés/bakeries where Nestly can be the authoritative transaction recorder or connect a pilot feed;
- optional 2 multi-outlet firms after single-outlet acceptance.

Exclude from the first cohort:

- high-volume five-outlet bubble-tea chains without POS integration;
- tuition centres needing household/course models;
- online/offline retail needing partial returns/e-commerce;
- clinics;
- stored-value businesses beyond the explicitly controlled pilot.

## Duration

- 4-week historical or observation baseline where possible;
- 2-week onboarding/stabilisation;
- 8-week intervention;
- minimum total: **12 weeks**;
- continue to day 90 for SME/customer retention.

## Comparison design

Preferred:

- deterministic customer-level treatment/holdout within each eligible SME;
- stratify by prior visits/value/recency and branch where sample permits;
- require verified exposure before treatment analysis;
- intention-to-treat plus exposed-treatment analysis;
- no messages to holdout;
- fixed attribution window per vertical;
- report uncertainty and minimum sample.

Fallback for small SMEs:

- matched historical cohort and staggered rollout;
- clearly label as directional, not causal.

Do not claim lift from a simple before/after comparison.

## Required data

- consent and channel preference history;
- customer identity/link and duplicate confidence;
- complete sale/line-item/refund/reversal history;
- source/coverage of transactions;
- programme/reward version;
- reward COGS or contribution estimate;
- message queue/provider receipt/interaction;
- campaign treatment/holdout/exposure;
- return transaction and attribution window;
- branch/staff/source;
- subscription plan/invoice/payment;
- support tickets and exception reasons.

## Activation milestones

### Business

1. application approved;
2. owner account activated;
3. business/branch configured;
4. programme published;
5. reward published;
6. first staff activated;
7. first customer joined;
8. first transaction recorded;
9. first eligible audience;
10. first campaign approved;
11. first message delivered;
12. first verified return;
13. first result viewed;
14. first renewal paid.

### Staff

1. invitation accepted;
2. first successful earn;
3. first redemption scan;
4. first correction/refund;
5. active in two consecutive weeks.

### Customer

1. join started/completed;
2. first programme viewed;
3. first earn;
4. progress viewed;
5. reward claimed;
6. reward redeemed;
7. second purchase;
8. active at 30/60/90 days.

## Weekly scorecard

### SME metrics

| Metric | Definition | Target |
| --- | --- | ---: |
| Onboarding completion | approved firms reaching programme live | ≥85% |
| Median time to launch | approval to programme live | <15 min guided work, excluding approval wait |
| Time to first customer | programme live to first linked customer | <1 day; counter join <30 sec returning context |
| Time to first campaign | eligible audience to approval | <3 min |
| Weekly owner activity | result/action view or approval | ≥70% |
| Staff activation | invited staff completing first transaction | ≥85% |
| Weekly active staff | activated staff using Nestly weekly | ≥80% |
| Campaign approval | eligible recommendations approved | 40–80% depending on fit |
| Attributed repeat revenue | post-exposure incremental revenue | positive with evidence state |
| Reward cost | redeemed reward COGS | captured ≥95% |
| Net campaign contribution | margin-adjusted incremental value minus costs | >0 for ≥60% mature campaigns |
| Paid conversion | pilot firms starting paid plan | ≥60% |
| Business retention | active/paid at day 30/60/90 | ≥85% / 75% / 70% |

### Customer metrics

| Metric | Target |
| --- | ---: |
| Join completion rate | ≥80% of starts |
| Median join time | <20 sec returning; <45 sec first-time |
| First-earn rate | ≥70% within first visit |
| Reward-progress view | ≥40% within 7 days |
| First redemption | ≥15% by 60 days, vertical-adjusted |
| Second purchase | +10% relative lift vs holdout/baseline target |
| 30/60/90-day active | measured by vertical cadence |
| Marketing opt-out | <5% overall; <2% per campaign |
| Qualified referral | ≥2% of active customers by day 90 |
| Review interaction | ≥5% of eligible prompts |

### Operational metrics

| Metric | Target |
| --- | ---: |
| Checkout time added | median <8 sec, p95 <20 sec |
| Transaction failure | <0.5% |
| Redemption failure (system-caused) | <0.5% |
| Duplicate profile | <1% of linked customers |
| Refund/reversal accuracy | 100% reconciliation |
| Campaign delivery | >95% accepted/delivered where measurable |
| False attribution | 0 known; audited <1% |
| Support tickets | <2 per business in week 1; <0.5/week thereafter |
| Transaction capture coverage | >90% manual or >80% automated feed |

## Failure thresholds

Pause expansion if any occur:

- cross-business data exposure;
- ledger/reward double-spend or unreconciled refund;
- holdout customer contacted;
- “sent/delivered” shown without evidence;
- false attribution >1%;
- staff transaction coverage <80% for two weeks;
- median checkout added time >15 seconds;
- join completion <60%;
- provider duplicate-send rate >0.1%;
- opt-out >10% or complaints;
- fewer than 50% of SMEs active at day 60;
- net contribution remains negative after mature campaigns.

## Product analytics event taxonomy

Required events:

```text
business_application_submitted
business_application_approved
owner_account_activated
onboarding_step_completed
programme_draft_created
programme_published
reward_published
branch_created
staff_invited
staff_activated
customer_join_started
customer_join_completed
transaction_recorded
points_earned
reward_progress_viewed
reward_claimed
redemption_qr_created
reward_redeemed
campaign_drafted
campaign_approved
message_queued
message_suppressed
message_delivered
message_failed
message_interacted
customer_returned
revenue_attributed
owner_result_viewed
subscription_started
subscription_renewed
subscription_upgraded
subscription_cancelled
```

Common properties:

- immutable event ID and occurred-at;
- business/branch/user role pseudonymous IDs;
- programme/reward/campaign version;
- source channel/integration;
- device class;
- result/error code;
- consent/exposure state where relevant;
- release/build identity;
- no unnecessary phone/email/name payload.

## Interview questions

### Owners

1. What did you expect Nestly to do automatically?
2. Which setup decision was hardest?
3. Can you explain the programme to a customer in one sentence?
4. Do you trust the recovered-revenue number? Why?
5. Which action would you approve without a consultant?
6. What task still duplicates your POS/workflow?
7. What result would justify the monthly fee?
8. What would make you cancel next month?

### Staff

1. When do you skip Nestly?
2. How many seconds does it add during a queue?
3. Which customer exception is hardest?
4. Can you recover from the wrong amount/refund?
5. Are name/phone search and branch assignment clear?
6. Do scan/redeem outcomes feel trustworthy?

### Customers

1. Did joining feel worth the time?
2. Can you explain the next reward and how to earn it?
3. What would make you open Nestly again?
4. Was the message useful or intrusive?
5. Did redemption feel clear and successful?
6. Do you understand what data/consent you gave?

## Retention criteria

### Owner

Retained if at day 60 the business:

- has ≥80% transaction coverage;
- has at least one active staff user;
- viewed/approved an action in the last 30 days;
- can state one credible value outcome;
- is paid or has accepted a paid conversion date.

### Staff

Retained if:

- ≥80% of activated staff use Nestly weekly where their role requires it;
- median operation remains within the time target;
- exception/error rate remains below threshold.

### Customer

Retained if:

- second purchase/revisit occurs within the vertical-specific cadence;
- programme progress is viewed or a value action occurs;
- no unresolved balance/refund discrepancy exists.

## Pilot governance

- Weekly evidence review by product, engineering and consultant lead.
- Sol independently reviews P0/P1 closure evidence.
- No causal claims until exposure and minimum-sample gates pass.
- No sector expansion based on anecdotal success.
- Every pilot issue is tagged to owner/staff/customer funnel stage and business metric.
- Release expansion requires owner approval after independent review.

