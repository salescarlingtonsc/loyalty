# SME Adoption Assessment

## Owner activation

### Current strength

Approval-first onboarding prevents unapproved firms from gaining an owner account. The platform can assign a sector, a default module bundle, firm/branch overrides and a consultant. Business branding, catalogue, branches, staff and programme mechanics are available after approval.

### Adoption friction

Production Grow configuration still presents loyalty, bring-backs, programme studio, stored value, referrals, memberships and gift cards as separate concepts. A non-technical owner must understand programme status, earn model, expiry, milestones, rewards, tiers, birthday benefits, QR redemption and automation before seeing the whole customer proposition.

The pending local v98 Grow experience is directionally correct:

- one programme overview;
- one guided recommended draft;
- an explicit live-flow diagram;
- edit individual parts after setup;
- advanced controls progressively disclosed;
- saves without hard refresh.

It is not yet production truth and must be measured with first-time owners.

### Target measurement

- median approved-account-to-workspace time: <5 minutes;
- median first-programme-live time: <15 minutes;
- no more than 8 required owner decisions for the recommended path;
- <15% setup abandonment;
- <1 assisted support contact per new firm.

## Staff activation and operational burden

Quick Earn is one of the stronger product surfaces. It supports:

- customer search by phone/name;
- branch and staff attribution;
- catalogue-first sales or controlled manual amounts;
- cash/card/PayNow/other tender recording;
- merchant QR scanning;
- a clear receipt;
- replay-safe server commands;
- fast correction for a safe subset.

Operational risks:

1. Staff must duplicate the transaction if the merchant already uses a POS.
2. Mobile business navigation expands a large module grid instead of preserving a counter-first action bar.
3. Partial/provider refunds are outside the supported matrix.
4. Network failure stops authenticated work.
5. Real peak-hour completion time has not been measured.

Likely abandonment pattern:

```text
launch enthusiasm
→ staff record most transactions
→ queue pressure or POS duplication appears
→ staff skip customer identification/Quick Earn
→ loyalty history becomes incomplete
→ campaigns and insights become less reliable
→ owner stops trusting ROI
→ subscription churn
```

## Owner workload

| Workflow | Current classification |
| --- | --- |
| Detect inactivity | Mostly automatic |
| Detect cadence decline | Automatic/heuristic |
| Identify VIP/value segments | Automatic |
| Recommend a starter programme | One-click draft, locally improved |
| Build an inactivity audience | Guided manual approval |
| Draft message | Manual/guided |
| Deliver message | Substantial manual work |
| Schedule provider campaign | Not available |
| Enforce frequency caps in real sends | Not verified |
| Stop ineffective campaigns | Not automatic |
| Weekly growth summary | Not available as a complete owner outcome brief |
| Explain recommendation | Partial |
| Measure incremental returns | Automatic math, unreliable exposure input |
| Calculate net profit after reward cost | Partial |

Nestly does not yet meet the preferred experience:

> Here is what is happening, why it matters, what it is worth, and the one safe action to approve.

## ROI visibility

The platform can calculate:

- treatment/holdout group sizes;
- return count and revenue in an attribution window;
- reversal-aware results;
- incremental return/revenue point estimates;
- expected campaign budgets/cost fields.

It cannot yet credibly answer:

- which customers actually received the message;
- delivery/open/click rate;
- net incremental contribution after actual reward COGS and messaging cost;
- statistical uncertainty/minimum sample;
- subscription payback;
- attributable value per S$1 of all-in cost.

Therefore, owners should see:

> “Observed Nestly-recorded returns; delivery not verified”

not:

> “This campaign brought customers back.”

## Industry fit

| Industry | Best mechanic | Current Nestly fit | Principal gap |
| --- | --- | ---: | --- |
| Café | digital stamps, birthday, win-back | 3/5 | POS ingestion, campaigns, refunds |
| Restaurant | visit/occasion rewards, reservations, win-back | 2.5/5 | group/occasion model, POS, messaging |
| Bubble tea | points/tiers/streaks/time-limited rewards | 3/5 | high-volume ingestion and fraud/refund scale |
| Bakery | stamps/pre-orders/seasonal offers | 3/5 | order/POS integration |
| Salon/nail/barber | rebooking, packages, birthday, cadence reminders | 4/5 | outbound reminder delivery |
| Fitness | membership, streaks, classes, churn | 3/5 | attendance/class integrations |
| Tuition | packages, referrals, lifecycle reminders | 2/5 | household/guardian/course/term model |
| Pet services | rebooking/service reminders/packages | 3/5 | pet profiles and reminder delivery |
| Retail | category rewards, tiers, online/offline identity | 2/5 | e-commerce/POS/refunds/merge |
| Clinic | appointment reminders/service lifecycle | 1.5/5 | sensitive-data restrictions and clinical boundaries |
| Automotive | service reminders/referrals/high-value lifecycle | 2/5 | vehicle/service schedule model |
| High-value low-frequency | referrals, lifecycle nurture, reviews | 2/5 | long-cycle attribution/playbooks |
| Renovation/property | referral, milestones, advocacy | 1.5/5 | case/project/household model |

Recommended first commercial wedge:

1. salons/spas;
2. owner-operated cafés using Nestly as the authoritative recorder;
3. appointment-led pet/barber/nail businesses.

Do not market every sector at launch.

## Multi-outlet usability

Strong foundations:

- firm-wide and branch-scoped views;
- staff branch assignments;
- branch-specific module/effective capability resolution;
- cross-outlet customer identity;
- branch-scoped redemption rechecks;
- enterprise rollups and exports;
- platform consultant firm scope.

Remaining adoption questions:

- can a five-outlet operator reconcile Nestly with the existing POS daily?
- how long does cross-branch exception handling take?
- are catalogue/service and entitlement changes easy to publish consistently?
- can branch managers understand only the data/actions they own?

These require a real chain pilot, not more static tests.

## Willingness to pay

The strongest monetisable proposition is not “more modules.” It is:

> Nestly identifies revenue at risk, gives the consultant/owner one evidence-backed action, and proves the net incremental contribution.

Customer Intelligence can support a consulting-led premium plan, but hiding it entirely removes product visibility. Recommended packaging:

- Core: customer wallet, earn/redeem, basic programme, branch operations;
- Growth Advisory: monthly platform-generated intelligence report + consultant action plan;
- Growth Automation: verified outbound campaigns, holdouts, net contribution and action inbox;
- Integrations: POS/e-commerce connectors for scale merchants.

Do not charge premium prices for “campaigns sent” before delivery truth exists.

## Reasons SMEs are likely to churn

1. Staff stop entering transactions.
2. Owner cannot see trusted net revenue impact.
3. Programme setup feels like expert configuration.
4. Campaign execution still creates owner work.
5. Refund/provider exceptions create support dependency.
6. Insights are delivered by Nestly only, without an always-visible proof trail.
7. The business pays while production billing/value outcomes remain unproven.

## One step beyond competitors

Build an **Owner Growth Action Inbox**:

```text
Observation
“34 regulars are overdue by 12+ days”
        ↓
Evidence
usual cadence, last visit, eligible consent, expected margin
        ↓
Recommended action
“Send a free add-on to 80%, hold back 20%”
        ↓
One approval
real provider delivery + suppression + budget cap
        ↓
Verified result
delivered, returned, net incremental contribution, uncertainty
```

This uses Nestly’s strongest existing assets and is more defensible than another dashboard.

