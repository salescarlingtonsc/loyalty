# 90-Day Adoption Roadmap

## Roadmap principles

1. Fix truth before adding growth claims.
2. Remove staff double-entry before scaling outlets.
3. Prove one channel and one vertical before adding breadth.
4. Treat refunds, consent and redemption as adoption features.
5. Measure owner, staff and customer funnels from day one.

## Days 0–30 — remove critical friction

### D0-1 Campaign truth hotfix

- **Problem:** recorded grants are called “sent”; lift is shown without exposure evidence.
- **Change:** rename all states to “recorded/ready to contact”; suppress “brought back” and incremental claims when exposure is unknown.
- **Users:** owner, consultant, platform.
- **Impact:** prevents loss of trust and bad commercial advice.
- **Complexity:** S.
- **Dependencies:** none.
- **Risk:** existing stakeholders may perceive reduced capability.
- **Acceptance:** no production UI says delivered/sent without a receipt; unknown-exposure campaigns cannot show causal verdicts.
- **Metric:** false-attribution rate = 0.

### D0-2 Verified exposure schema and worker contract

- **Problem:** no authoritative delivery lifecycle.
- **Change:** immutable message/exposure/receipt rows and provider-neutral state machine.
- **Users:** owner, customer, consultant.
- **Impact:** makes recovery automation and attribution possible.
- **Complexity:** L.
- **Dependencies:** channel/provider decision.
- **Risk:** consent/provider callback complexity.
- **Acceptance:** queue, suppress, deliver, fail, retry and callback replay tests; holdout never enters send queue.
- **Metric:** delivery rate, suppression correctness.

### D0-3 Refund product contract

- **Problem:** partial/provider-settled refunds are unsupported.
- **Change:** define cash/card/PayNow/split/gift-card/package refund matrix and implement the first provider-aware append-only path.
- **Users:** staff, owner, customer.
- **Impact:** removes a broad-launch blocker.
- **Complexity:** XL.
- **Dependencies:** provider settlement model.
- **Risk:** accounting/loyalty reconciliation.
- **Acceptance:** original + refund allocations reconcile across revenue, payment, tax, points and customer history; replays safe.
- **Metric:** refund accuracy 100%; reconciliation exceptions 0.

### D0-4 Mobile frontline counter shell

- **Problem:** large mobile module grid slows repeat tasks.
- **Change:** drawer plus persistent Quick Earn, scan and appointment actions.
- **Users:** frontline staff.
- **Impact:** lower peak-hour friction.
- **Complexity:** M.
- **Dependencies:** none.
- **Risk:** permission-based action visibility.
- **Acceptance:** three actions reachable in one tap from every staff page; 375/390px no overflow; role-disabled actions absent.
- **Metric:** median earn/redeem interaction time.

### D0-5 Core adoption instrumentation

- **Problem:** Nestly cannot calculate activation funnels.
- **Change:** first-party events for business, staff, customer, campaign and subscription milestones.
- **Users:** product/platform team.
- **Impact:** identifies real adoption failures.
- **Complexity:** M.
- **Dependencies:** event taxonomy and privacy review.
- **Risk:** duplicate/noisy events or sensitive payloads.
- **Acceptance:** idempotent events, stable IDs/timestamps, documented properties, funnel queries and deletion/retention rules.
- **Metric:** event completeness >99%, duplicate rate <0.5%.

### D0-6 Release pending Grow UX after independent acceptance

- **Problem:** programme setup is fragmented and hard-refresh behaviour is confusing.
- **Change:** complete v98 unified overview, guided draft, visual flow and editable summary.
- **Users:** owner.
- **Impact:** faster launch, lower support.
- **Complexity:** M.
- **Dependencies:** Sol review and owner approval.
- **Risk:** local moving snapshot; regression in existing programmes.
- **Acceptance:** first-time owner usability test; no hard refresh; all values round-trip; production flags/status remain truthful.
- **Metric:** median first-programme-live <15 minutes.

### D0-7 Real-device acceptance

- **Problem:** passkey/camera/PWA behaviour is not physically verified.
- **Change:** run iPhone and Android journey matrix.
- **Users:** customers, staff.
- **Impact:** prevents launch-day device failures.
- **Complexity:** S.
- **Dependencies:** devices and staging/test identities.
- **Risk:** provider/CAPTCHA configuration.
- **Acceptance:** join, login, passkey, scan, redeem, booking, slow network and retry evidence captured.
- **Metric:** critical journey success >98%.

## Days 31–60 — prove repeat revenue

### D31-1 Launch one communications channel

- **Problem:** owner manually contacts customers.
- **Change:** ship one consent-aware channel; recommended priority is Web Push/in-app for cost plus one transactional reminder channel, then evaluate WhatsApp.
- **Users:** owner, customer.
- **Impact:** closes the recovery loop.
- **Complexity:** L.
- **Dependencies:** D0-2, provider, consent policy.
- **Risk:** spam/quiet-hour violations.
- **Acceptance:** verified receipts, retries, opt-out, frequency caps, duplicate suppression and dead-letter alerts.
- **Metric:** delivery >95%, opt-out <2% per campaign, duplicate sends 0.

### D31-2 Exposure-correct attribution

- **Problem:** returns can be counted without exposure.
- **Change:** measure only post-exposure returns; add minimum sample and uncertainty.
- **Users:** owner, consultant.
- **Impact:** credible incremental-revenue proof.
- **Complexity:** L.
- **Dependencies:** D0-2/D31-1.
- **Risk:** fewer campaigns will produce a decisive result.
- **Acceptance:** exposure timestamp required; pre-exposure return excluded; confidence/min-N state shown.
- **Metric:** false-attribution <1%; 100% result cards show evidence state.

### D31-3 Reward economics

- **Problem:** revenue is shown without reliable reward COGS/margin.
- **Change:** require COGS/contribution estimate for rewards and key catalogue items.
- **Users:** owner, consultant.
- **Impact:** turns revenue into net contribution.
- **Complexity:** M.
- **Dependencies:** catalogue and reporting.
- **Risk:** owner estimates may be poor.
- **Acceptance:** no “profitable” result without cost inputs; confidence shown when estimated.
- **Metric:** net campaign contribution; contribution/cost ratio.

### D31-4 Weekly growth summary

- **Problem:** owner must hunt through modules.
- **Change:** weekly summary: what changed, data confidence, money at risk, action needing approval, verified results.
- **Users:** owner, consultant.
- **Impact:** value while owner is busy.
- **Complexity:** M.
- **Dependencies:** instrumentation and intelligence.
- **Risk:** alert fatigue.
- **Acceptance:** one concise summary; no vanity metrics without action; user can drill into definition/evidence.
- **Metric:** weekly summary open rate; action approval rate.

### D31-5 One transaction ingestion pilot

- **Problem:** manual double-entry.
- **Change:** signed webhook/API connector for one selected pilot POS or structured receipt source.
- **Users:** staff, owner.
- **Impact:** materially reduces operational cost.
- **Complexity:** XL.
- **Dependencies:** partner access and canonical ingestion contract.
- **Risk:** vendor variance and identity matching.
- **Acceptance:** >99.5% deduplicated ingestion; refund parity; dead-letter reconciliation.
- **Metric:** automated transaction share >80% for connected pilots.

### D31-6 Customer home next action

- **Problem:** ranked action is calculated but not prominent.
- **Change:** one merchant-specific hero with reason, deadline/value and direct CTA.
- **Users:** customer.
- **Impact:** increases repeat engagement.
- **Complexity:** S/M.
- **Dependencies:** actionable wallet truth.
- **Risk:** stale/unavailable action.
- **Acceptance:** action revalidated at click; absent features stay hidden; fallback remains honest.
- **Metric:** action-view-to-action rate.

## Days 61–90 — build the adoption advantage

### D61-1 Three vertical starter playbooks

- **Problem:** sector bundles are not outcome playbooks.
- **Change:** café, salon/spa and appointment-led service templates with safe defaults and cost/attainability simulation.
- **Users:** owner, consultant.
- **Impact:** faster time to value and better relevance.
- **Complexity:** L.
- **Dependencies:** pilot data.
- **Risk:** over-generalising verticals.
- **Acceptance:** template preview explains mechanic, customer journey, cost and success metric; all settings editable.
- **Metric:** template adoption, time-to-live, 30-day owner retention.

### D61-2 Consultant Growth Action Inbox

- **Problem:** platform intelligence is rich but operationally fragmented.
- **Change:** firm-scoped, evidence-backed actions for assigned consultants; owner receives approved summary/action.
- **Users:** consultant, owner.
- **Impact:** differentiates Nestly’s service model.
- **Complexity:** L.
- **Dependencies:** intelligence, messaging, attribution.
- **Risk:** consultant scope/permission mistakes.
- **Acceptance:** assigned-firm isolation, definitions/confidence, audit trail, owner approval where required.
- **Metric:** consultant action throughput, SME renewal.

### D61-3 Identity quality and merge

- **Problem:** duplicate/household customers fragment intelligence.
- **Change:** candidate-duplicate queue, safe merge with provenance, and optional guardian/household relationships.
- **Users:** owner, consultant, customer.
- **Impact:** better data and tuition/retail fit.
- **Complexity:** XL.
- **Dependencies:** identity policy.
- **Risk:** wrongful merge.
- **Acceptance:** preview, customer-impact summary, reversible linkage or immutable merge map, dual-authority for high-risk cases.
- **Metric:** duplicate-profile rate.

### D61-4 Referral/review qualified outcomes

- **Problem:** outbound link/record does not prove qualified advocacy.
- **Change:** reward referrals after qualified first purchase; track review-link interaction and supported completion evidence.
- **Users:** owner, customer.
- **Impact:** completes acquisition/advocacy loops.
- **Complexity:** M/L.
- **Dependencies:** transaction ingestion, attribution.
- **Risk:** abuse and external platform limitations.
- **Acceptance:** self/household/rate controls; no reward before qualification.
- **Metric:** qualified referral rate, review completion proxy.

### D61-5 Multi-outlet benchmark and data-confidence report

- **Problem:** chains need comparable branch performance.
- **Change:** normalised branch cohort/retention benchmarks with coverage/confidence.
- **Users:** multi-outlet owner, consultant.
- **Impact:** supports premium advisory value.
- **Complexity:** L.
- **Dependencies:** transaction completeness.
- **Risk:** misleading small-branch comparisons.
- **Acceptance:** minimum sample; comparable period/segment; no ranking when data quality is low.
- **Metric:** branch action adoption and lift.

## Day-90 exit gate

Nestly advances beyond limited pilot only if:

- no false “sent”/causal states;
- one real provider and one real transaction ingestion path operate;
- refund matrix covers pilot tender methods;
- physical-device critical journeys pass;
- product funnel completeness exceeds 95%;
- at least 10 SMEs complete baseline + intervention;
- at least 70% of pilot firms remain active at day 60;
- at least 60% of active firms have one verified campaign result;
- net incremental contribution is positive for the target cohort;
- frontline transaction compliance is >90% or automated ingestion >80%.

