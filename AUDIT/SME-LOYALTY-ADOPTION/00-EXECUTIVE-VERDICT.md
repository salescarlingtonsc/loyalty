# Independent Product-Adoption Audit — Executive Verdict

Audit date: 2026-07-29  
Repository: `/tmp/nestly-v97-workspace-localization`  
Reviewed branch: `codex/v97-workspace-localization`  
Production base reviewed: `90afc7786c8a9df999beed50f290e6c7eb96fda9` (`v96`)  
Local-only work also inspected: uncommitted `v97` workspace localisation and `v98` Grow UX changes

## Verdict

**CONDITIONAL PASS for a narrow, instrumented pilot. FAIL for a broad commercial launch.**

**Audit completeness gate:** the brief's five complete disposable-database/browser scenario journeys were not executed end to end. Scenario-relevant contracts were executed (157/157 passed), but fresh runtime firms/customers, physical-device timing, real delivery and provider refund steps remain incomplete. This prevents a full audit PASS and is part of the launch decision—not a footnote.

Nestly has unusually strong transaction provenance, customer/business synchronisation, multi-outlet permissions, merchant-confirmed reward redemption, programme versioning, and reversal-aware holdout measurement. Those are real foundations for a defensible retention product.

The commercial loop nevertheless breaks in two places:

1. A retention grant is displayed as an offer “sent” even though Nestly does not deliver or verify the message. The owner must contact customers manually. Delivery, open, click and actual exposure are unknown, so subsequent causal “brought back” claims are not yet defensible.
2. Transactions are normally entered manually through Quick Earn. No production POS, e-commerce, receipt, or payment-linked ingestion path was found. High-volume firms would duplicate every transaction; once staff stop doing that, loyalty, segmentation, recovery and ROI measurement all decay together.

The test suite is strong, but it proves implementation contracts rather than product adoption. No 10–20 SME pilot, verified campaign delivery, measured peak-hour checkout timing, live billing cohort, or live retention-result cohort exists yet.

## Adoption scores

| Dimension | Score |
| --- | ---: |
| SME owner adoption | 56/100 |
| Staff adoption | 58/100 |
| Customer adoption | 70/100 |
| Technical reliability | 78/100 |
| Commercial value | 48/100 |
| Overall launch readiness | 54/100 |

Numerical scores do not override the P0 attribution and workflow-ingestion blockers.

## 30-category assessment

Scale: 0 missing; 1 placeholder/critically broken; 2 major adoption barriers; 3 functional with meaningful improvement required; 4 commercially strong; 5 best-in-class.

| # | Category | Score /5 | Key reason |
| ---: | --- | ---: | --- |
| 1 | Owner onboarding | 3 | Approval-first and sector bundles exist; first programme remains cognitively heavy in production. |
| 2 | Staff onboarding | 3 | Roles and invitations exist; real activation timing has not been measured. |
| 3 | Customer enrolment | 3 | Mobile web and QR linking work; phone, password, OTP and profile sequence misses the proven under-20-second target. |
| 4 | Customer value proposition | 4 | Programme-specific balances, progress, rewards, expiry and merchant identity are clear. |
| 5 | Checkout speed | 3 | Quick Earn is compact, but manual duplication and mobile navigation remain friction. |
| 6 | Loyalty-mechanic flexibility | 4 | Points, stamps, rewards, tiers, packages, memberships, gift cards and stored-value foundations exist. |
| 7 | Industry suitability | 2 | Sector module bundles exist, but differentiated retention playbooks are shallow outside café/salon use cases. |
| 8 | Automation | 2 | Schedulers and recommendation drafts exist; outbound recovery still needs manual action. |
| 9 | Personalisation | 2 | Segments and customer intelligence exist; product/category recommendations and exposure-aware messaging are limited. |
| 10 | Customer segmentation | 3 | Lapsed/regular/value groupings and branch/time filters exist. |
| 11 | Churn detection | 3 | Overdue cadence and inactivity logic exist; prediction quality and live outcomes are unproven. |
| 12 | Campaign execution | 2 | Audience/grants/holdouts exist; real delivery is missing. |
| 13 | Communication consent | 4 | Consent events, preferences and opt-out structures are present; counter wording/evidence can improve. |
| 14 | Revenue attribution | 2 | Holdout and reversal-aware math are strong, but exposure is unverified. |
| 15 | ROI reporting | 2 | Incremental revenue is modeled; net contribution and subscription payback are incomplete. |
| 16 | Reward economics | 3 | Budgets and some cost fields exist; manual-item COGS/gross margin are unreliable or absent. |
| 17 | Multi-outlet operations | 4 | Branch scoping, assignments, reports and redemption controls are strong. |
| 18 | POS/workflow integration | 1 | No real POS/e-commerce/payment-linked ingestion was found. |
| 19 | Mobile customer experience | 4 | Responsive PWA, passkeys, QR join and fixed customer navigation are strong. |
| 20 | Owner dashboard clarity | 3 | Operational dashboards exist; growth proof is not yet the primary truth. |
| 21 | Staff usability | 3 | Quick Earn and scan flows are good; mobile workspace navigation and refunds need work. |
| 22 | Customer trust | 4 | Pending-until-merchant-confirmed redemption and transparent histories are strong. |
| 23 | Security/business isolation | 4 | RLS, guarded RPCs and role/branch tests are extensive; production advisor warnings still require periodic triage. |
| 24 | Fraud prevention | 4 | Idempotency, branch rechecks, immutable ledgers and QR consumption controls are strong. |
| 25 | Analytics instrumentation | 1 | Domain events exist; complete product-adoption funnels do not. |
| 26 | Referral growth loop | 3 | Referral records and programme controls exist; advocacy completion and abuse evidence are incomplete. |
| 27 | Review growth loop | 2 | Review links/prompts exist; completed-review attribution is not verified. |
| 28 | Customer-recovery loop | 2 | Detection, holdout and grant logic exist; actual contact delivery is missing. |
| 29 | Subscription stickiness | 2 | Billing automation exists, but production billing tables and proven ROI cohort are empty. |
| 30 | Overall adoption readiness | 2 | Strong technical base; broad adoption economics are not yet proven. |

Total: **84/150 = 56%**.

## Strongest current capability

Merchant-confirmed redemption and synchronised financial/loyalty provenance:

- a customer prepares a pending reward QR;
- no balance changes while it is pending;
- authorised branch staff scan and confirm;
- current programme and branch eligibility are rechecked;
- the redemption is idempotent and auditable;
- the customer wallet receives the same durable outcome.

This is materially stronger than a paper stamp card and many basic POS loyalty add-ons.

## Biggest product weakness

**Nestly can measure a Nestly-recorded return, but cannot yet prove that a Nestly-delivered message caused it.** The UI currently crosses that evidentiary boundary.

## Top five launch blockers

1. **P0 — False-success campaign exposure:** “Offers sent” means grants recorded, not messages delivered.
2. **P0 — Manual transaction duplication:** no production POS/e-commerce/payment-linked ingestion.
3. **P0 — Incomplete real-world refunds:** partial and provider-settled card/PayNow refund flows are not launch-complete.
4. **P1 — Missing product funnel instrumentation:** business, staff and customer activation/retention funnels cannot be calculated reliably.
5. **P1 — Commercial proof absent:** no live campaign cohort, verified delivery cohort, live billing cohort or 10–20 SME pilot.

## Top five competitive advantages

1. Cross-business customer wallet without requiring a native application download.
2. Merchant-issued QR enrolment with no customer self-search/linking.
3. Pending-until-confirmed reward QR redemption with branch and role rechecks.
4. Append-only, replay-safe loyalty and financial provenance with reversal support.
5. Deterministic holdouts and reversal-aware incrementality math—once actual exposure is captured.

## Product classification

| Classification | Current status |
| --- | --- |
| Digital stamp/points tool | Exceeds this category |
| Loyalty-management platform | **Yes** |
| Retention platform | **Yes, with manual campaign delivery** |
| Automated customer-growth platform | **No** |

## 25 direct SME questions

| # | Question | Answer | Evidence-based reason |
| ---: | --- | --- | --- |
| 1 | Can an owner launch without becoming a loyalty expert? | Partially | Defaults and drafts exist; production Grow setup still exposes many concepts. |
| 2 | Can a customer join without downloading another app? | Yes | Mobile-web QR journey and PWA are supported. |
| 3 | Can staff operate without slowing queues? | Partially | Quick Earn is compact; manual double-entry and mobile navigation remain. |
| 4 | Does it keep working while the owner is busy? | Partially | Schedulers and detections run; campaign contact still needs owner work. |
| 5 | Can it identify customers likely to disappear? | Partially | Cadence/inactivity logic exists; predictive validity is unproven. |
| 6 | Can it recommend the next best action? | Partially | Recommendations are calculated, but customer/owner presentation and execution are incomplete. |
| 7 | Can it bring inactive customers back? | Partially | It can identify and grant offers; it does not deliver them. |
| 8 | Can it prove they returned because of Nestly? | No | Exposure is not verified. |
| 9 | Can it show incremental rather than vanity revenue? | Partially | Holdout math exists; input exposure is unreliable. |
| 10 | Can it calculate reward profitability? | Partially | Some expected costs exist; direct COGS/margin are incomplete. |
| 11 | Can it prevent over-messaging? | Partially | Preferences/quiet-hour structures exist; no real provider path was verified. |
| 12 | Can it support businesses where points are inappropriate? | Yes | Stamps, packages, memberships, referrals, booking/rebooking and stored value foundations exist. |
| 13 | Can it work across outlets? | Yes | Branch-scoped operations and consolidated platform reporting exist. |
| 14 | Can it prevent duplicate customer identities? | No | Phone normalisation helps; owner-facing merge/household resolution is missing. |
| 15 | Can it reverse points after refunds? | Partially | Ledger compensation is proven for supported reversals; partial/provider refund coverage is incomplete. |
| 16 | Can it prevent reward/referral abuse? | Partially | Redemption protections are strong; referral/self-referral coverage is less complete. |
| 17 | Can it show staff exactly what to do? | Partially | Quick Earn is guided; mobile workspace and exception recovery need improvement. |
| 18 | Can customers understand reward progress? | Yes | Balance, progress, reward and expiry surfaces exist. |
| 19 | Can it create a useful first result quickly? | Partially | The mechanics can start quickly; measurable retention needs transactions and time. |
| 20 | Is it compelling enough to keep paying monthly? | Partially | Strong operations, but ROI proof and unattended recovery are not yet credible. |
| 21 | Is the customer experience compelling for repeat use? | Partially | Programme-specific visuals/progress are strong; customer next-best action is underused. |
| 22 | Does it outperform a physical stamp card? | Yes | Identity, histories, branch controls, expiry, recovery foundations and measurement are superior. |
| 23 | Does it outperform a basic POS loyalty add-on? | Partially | Better cross-business wallet and measurement; worse transaction capture without integration. |
| 24 | Is there a defensible advantage beyond generic loyalty? | Yes | Confirmed QR redemption plus immutable provenance and holdout measurement are defensible. |
| 25 | Does it deserve “automated customer-growth system”? | No | Delivery, transaction ingestion, instrumentation and unattended optimisation are incomplete. |

## Formal product-adoption verdict

```text
FORMAL PRODUCT-ADOPTION VERDICT

Repository / commit: /tmp/nestly-v97-workspace-localization @
90afc7786c8a9df999beed50f290e6c7eb96fda9, with uncommitted v97/v98 inspected separately
Audit date: 2026-07-29
Overall score: 56/100
SME owner adoption score: 56/100
Staff adoption score: 58/100
Customer adoption score: 70/100
Technical reliability score: 78/100
Commercial-value score: 48/100

Current product classification:
Strong loyalty-management and assisted-retention platform; not an automated
customer-growth platform.

Launch recommendation:
Limited, instrumented pilot only. Do not broadly commercialise yet.

P0 blockers:
- Offer grants are labelled as messages sent; delivery/exposure is unverified.
- High-volume transaction capture depends on manual duplicate entry.
- Partial/provider-settled refunds are not supported end to end.

P1 blockers:
- No real outbound recovery provider and delivery/open/click evidence.
- Product-adoption funnel instrumentation is incomplete.
- Reward COGS/net contribution is incomplete.
- No live commercial pilot evidence.

Strongest defensible advantage:
Merchant-confirmed QR redemption plus append-only, reversal-aware provenance
and deterministic holdout measurement.

Biggest reason SMEs may reject the product:
Staff must re-enter sales and owners cannot yet trust the campaign ROI claim.

Biggest reason staff may stop using it:
Double-entry and exception/refund friction during peak service.

Biggest reason customers may not join:
The QR journey still requires phone, password, OTP and profile completion.

Biggest reason customers may not return:
Nestly does not yet deliver timely, verified personalised recovery messages.

Can the platform prove incremental repeat revenue? No, not while exposure is unverified.
Can it operate with minimal owner involvement? Partially.
Can customers join without downloading an application? Yes.
Can staff use it during peak periods? Partially; not proven at high volume.
Does it deserve to be called an automated customer-growth platform? No.

Final verdict: CONDITIONAL PASS for limited pilot; FAIL for broad launch.
```
