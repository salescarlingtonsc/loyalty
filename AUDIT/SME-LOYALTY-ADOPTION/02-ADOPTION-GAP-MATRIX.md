# Adoption Gap Matrix

Severity:

- **P0:** trust, security, data-integrity or commercially fatal
- **P1:** major adoption or revenue blocker
- **P2:** material usability or competitiveness issue
- **P3:** improvement

| Gap | User affected | Current evidence | Severity | Adoption impact | Root cause | Recommended resolution |
| --- | --- | --- | --- | --- | --- | --- |
| Offer grants are labelled “Offers sent” | Owner, consultant, customer | UI admits messaging is not automated; `issue_campaign_offer` records a grant but not verified delivery | P0 | Creates false causal confidence and can misstate ROI | Grant, exposure and delivery are conflated | Rename immediately; add exposure/delivery state machine; suppress causal verdict until verified exposure |
| Attribution can start before contact | Owner, consultant | v50 measures from campaign activation while real/manual contact is unknown | P0 | Pre-contact returns may be attributed to the campaign | No authoritative `exposed_at` | Start attribution at verified/manual-confirmed exposure; reject pre-exposure returns |
| No POS/e-commerce/payment ingestion | Staff, owner | Quick Earn is the transaction source; no production connector found | P0 | Double-entry causes frontline abandonment and destroys downstream data quality | Product was built as an authoritative recorder before integration | Pilot with Nestly-authoritative merchants; then ship one connector/webhook ingestion contract |
| Refund matrix is incomplete | Owner, staff, customer | v20 full reversals only; provider-settled/partial/mixed cases rejected; v84 correction is cash-limited | P0 | Real retail/F&B disputes cannot be resolved consistently | Financial safety scope deliberately narrow | Implement provider-aware partial/full refunds with proportional loyalty compensation and immutable receipts |
| Stored value is single-business pilot only | Owner, customer, platform | v69 unique tripwire allows one live business platform-wide | P0 for selling stored value broadly | Cannot safely promise general multi-tenant stored value | Controlled cutover was intentionally narrow | Keep hidden/pilot-labelled until multi-tenant reconciliation and cutover acceptance pass |
| No real outbound campaign provider | Owner, customer | No production SMS/email/WhatsApp provider; manual WhatsApp contact list | P1 | Recovery loop depends on owner labour | Provider-neutral outbox stopped at capture/manual stage | Integrate one channel first with consent, quiet hours, retries, suppression and delivery receipts |
| No delivered/opened/clicked evidence | Owner, consultant | Production notification/campaign activity rows are empty; no provider receipt path | P1 | Cannot diagnose creative/channel effectiveness | Delivery instrumentation absent | Add message, provider-attempt, receipt and interaction tables/events |
| No statistical guardrails on lift | Owner, consultant | Holdout math returns point estimates without minimum sample/confidence/significance | P1 | Small cohorts can look conclusive | Measurement engine lacks uncertainty presentation | Add minimum-N, confidence interval, significance and “insufficient evidence” state |
| Manual-item reward cost can be zero/incomplete | Owner | Expected-cost fields exist, but no reliable COGS/margin source for free-item rewards | P1 | “Incremental revenue” may hide negative contribution | Catalogue lacks required economic cost data | Add item COGS/contribution margin; report net incremental contribution |
| Product funnels are not instrumented | Product team, owner | No PostHog/Mixpanel/Amplitude/GA/Sentry; domain events do not cover adoption funnels | P1 | Cannot identify activation/churn bottlenecks | Operational event model was prioritised over product analytics | Add privacy-safe first-party funnel events and release/error telemetry |
| Live billing cohort is empty | Platform owner | Billing code/functions exist; production billing tables have zero rows | P1 | Subscription lifecycle and willingness-to-pay are unproven | Implementation completed before merchant billing launch | Run provider sandbox and first controlled live invoice/renewal/refund/chargeback rehearsal |
| Platform alerts lack proven recipient/runbook | Platform owner | Prior readiness records still mark alert evidence outstanding | P1 | Failures may remain invisible | Operational ownership incomplete | Configure monitored alert destination, severity rules, dashboards and rehearsal |
| Customer Intelligence is unreachable to SME | Owner | Route/RPC/export exist; owner menu is globally hidden by product decision | P1/P2 | Owner cannot self-validate value; upsell is invisible | Feature was hidden instead of entitlement-gated | Make a platform-generated monthly report plus paid preview/trial with clear scope |
| Customer identity merge/household model missing | Customer, owner | Phone uniqueness helps; no owner-facing merge or guardian/sibling model | P1 for tuition/retail | Duplicates fragment spend and rewards | Identity model is individual phone-first | Build reviewable merge with provenance and household relationships |
| Frontline mobile navigation is not app-like | Staff | Below 960px workspace nav becomes a large grid above content | P1 | Repeated scrolling during peak service | Desktop information architecture collapses rather than transforms | Add drawer + persistent Quick Earn/scan/appointment action bar |
| Actionable-wallet result is underused | Customer | RPC is called; successful home mostly renders programme tiles instead of ranked action/reason/CTA | P1/P2 | Customer misses the most relevant reason to return | Data and presentation paths diverged | Render one ranked action hero per selected programme |
| First join under 20 seconds is unproven | Customer, owner | QR + phone + password + OTP + profile are required on first use | P1/P2 | Queue abandonment risk | Trust/profile capture front-loaded | Measure funnel; defer nonessential profile; support passkey after verified phone |
| Counter marketing consent wording is weak | Customer, staff | Simple “Marketing consent given” checkbox; event provenance exists | P2 | Staff may record consent without clear customer confirmation | UI optimised for speed | Show concise customer-confirmed wording and consent policy/version |
| No verified frequency-cap execution | Customer | Preference/quiet-hour structures exist; real delivery path absent | P2 | Future campaigns risk fatigue/spam | No live provider means no end-to-end suppression proof | Add business/customer/global caps and duplicate/cross-outlet suppression tests |
| Sector bundles are module sets, not playbooks | Owner | Seven sector bundles; limited vertical retention defaults | P1/P2 | Owners still make expert decisions; poor fit outside cafés/salons | Entitlement templating was mistaken for outcome templating | Create outcome-led café, salon and appointment-led starter playbooks first |
| Grow setup is confusing in production | Owner | Production exposes multiple submodules; local v98 unifies overview/draft/advanced setup | P2 | Setup abandonment and support dependency | Feature-by-feature IA | Complete independent review and release v98; measure first-programme time |
| Customer programme detail can be too long | Customer | Many histories/settings/benefits appear in one page | P2 | Repeat users hunt for the next action | All truth surfaces are vertically accumulated | Use summaries/tabs while preserving full audit history |
| Passkey depends on Turnstile readiness | Customer | Passkey button is disabled until challenge completes | P2 | Biometric login is not always immediate | Authentication gate sequence | Allow supported conditional passkey mediation where risk controls permit |
| Offline authenticated operation is absent | Staff, customer | Service worker caches shell only | P2 | Unstable internet stops checkout | Correct security-first design lacks queued offline mode | Do not add risky offline writes first; provide fast recovery/status and optional bounded offline sale queue later |
| Appointment communication is in-app only | Customer, staff | UI explicitly says no SMS/WhatsApp; no provider path | P2 | No-shows and missed reminders | Messaging integration missing | Reuse the verified communications worker for booking reminders |
| Review loop stops at outbound link | Owner | Public review link/prompt exists; completion not observed | P2 | Cannot prove advocacy/review conversion | Third-party completion signal absent | Track click; use optional owner-confirmed/imported completion where provider API unavailable |
| Referral abuse coverage is incomplete | Owner, customer | Referral tables/programs exist; redemption controls are stronger than referral controls | P2 | Self-referral/reward farming risk | Referral lifecycle less mature | Add self/household/device/rate rules, delayed reward after qualified transaction |
| Platform authorisation infers context by caller-name regex | Admin, sales staff | v89 derives module/mode through `pg_context` caller text | P1 technical debt | RPC rename/new call paths can create brittle access behaviour | Implicit convention-based authorisation | Replace with explicit per-module read/write wrappers/claims; adversarial tests |
| Supabase advisor warnings are numerous | Platform owner | 0 ERROR, 334 WARN, 143 INFO security findings; 741 performance findings | P2 | Scale/maintenance drift may create later incidents | Many guarded RPC-only surfaces and permissive policy overlap | Maintain explicit allowlist, function-guard tests, policy consolidation and FK index plan |
| Static SPA monolith is large | Engineering, all users | `app/index.html` ~14k lines; platform console ~6k lines | P2 | Regression risk and slower feature delivery | Single-file architecture accumulated | Split route/domain services and shared components without changing behaviour |
| Pending v97/v98 are not production truth | Owner, platform user | Dirty local branch only | P2 | Audit cannot credit localisation/unified Grow as launched | Release gate correctly not crossed | Sol review, owner approval, then controlled release and browser acceptance |
| No physical-device acceptance | Customer, staff | Automated/browser contract tests only; no current iPhone/Android camera/passkey run | P1 before broad launch | Camera/passkey/PWA failures may appear only on devices | Device matrix not executed | Run iPhone Safari/PWA and Android Chrome join, passkey, scan, redeem, offline/recovery journeys |

## Required technical behaviour for the top recommendations

### 1. Exposure-truth campaign lifecycle

- **User problem:** the owner sees “sent” and lift without proof the customer received anything.
- **Existing evidence:** `issue_campaign_offer` inserts campaign grants; Grow says messaging is manual while cards say “Offers sent.”
- **Why current approach reduces adoption:** a later Nestly-recorded purchase can be presented as causal even if the customer was never contacted.
- **Proposed product behaviour:** distinguish approved, queued, attempted, delivered, interacted and converted; use “delivery unknown” for legacy/manual records.
- **Proposed technical approach:** immutable exposure/receipt events; provider/manual-confirmed exposure; attribution window begins at exposure, not activation.
- **Affected components:** Grow UI; `retention_campaigns`, members, grants, returns; outbox; provider Edge Function/worker; attribution RPC.
- **Migration:** add immutable exposure/receipt rows rather than mutating economic grants; backfill existing grants as `delivery_unknown`.
- **Privacy/security:** enforce consent/channel preference at queue and send time; minimise contact payload; redact provider logs.
- **Events:** `campaign_approved`, `message_queued`, `message_delivered`, `message_failed`, `message_interacted`, `conversion_qualified`.
- **Edge cases:** opt-out after queue, duplicate provider callback, delivery after reward expiry, return before exposure, cross-outlet duplicate, provider retry.
- **Acceptance:** no “sent” label without delivery evidence; no attributed return before exposure; replay-safe receipts; holdout never contacted.
- **Recommended test coverage:** provider capture, callback signature/replay, consent race, holdout exclusion, pre-exposure return, cross-tenant denial, statistical/min-N result states.
- **Expected business metric:** delivered campaigns, recovered customers, net incremental contribution and renewal.
- **Expected customer metric:** relevant-message interaction, opt-out and complaint rate.

### 2. Provider-aware refund lifecycle

- **User problem:** staff cannot correctly handle partial/card/PayNow/mixed refunds.
- **Existing evidence:** v20 rejects partial/provider-settled cases; v84 correction only supports a narrow safe cash matrix.
- **Why current approach reduces adoption:** merchants either leave Nestly inconsistent with the payment provider or depend on support/manual work.
- **Proposed product behaviour:** select refundable lines/amount, preview exact financial/loyalty effects, submit, show pending provider status, then append the settled result.
- **Proposed technical approach:** refund operation/allocation records, provider command/receipt adapter, proportional points/reward compensation and one reconciliation projection.
- **Affected components:** Sales/Quick Earn UI; sale/payment/line-item/loyalty/gift-card/package ledgers; provider command functions; customer history.
- **Migration:** append refund operations and allocations; never edit original sale facts.
- **Security:** owner/manager permission; branch scope; idempotency; provider signature/receipt validation.
- **Events:** `refund_requested`, `refund_provider_pending`, `refund_settled`, `refund_failed`, `loyalty_compensated`.
- **Edge cases:** points already spent, expired rewards, split tender, partial gift card/package use, duplicate callbacks, provider success after UI timeout.
- **Acceptance:** original + refunds reconcile to tender, revenue, tax, points and customer history; duplicate request is safe.
- **Recommended test coverage:** full tender/refund matrix, two-session concurrency, failure injection, delayed/duplicate callback, report/wallet reconciliation and cross-branch denial.
- **Expected business metric:** refund completion, reconciliation exceptions and support cost.
- **Expected customer metric:** dispute rate and balance/history correctness.

### 3. Transaction ingestion contract

- **User problem:** staff must record a sale twice.
- **Existing evidence:** Quick Earn writes canonical sales, but no production POS/e-commerce/payment-linked ingestion exists.
- **Why current approach reduces adoption:** staff compliance falls during queues and every downstream insight becomes incomplete.
- **Proposed product behaviour:** selected pilot transactions arrive automatically and appear exactly like safe Quick Earn records with source/confidence visible.
- **Proposed technical approach:** signed per-business webhook/API, normaliser, source/branch/catalogue mapping, identity matcher and dead-letter reconciliation.
- **Affected components:** new integration API/webhook, source mapping tables, transaction normaliser, client identity resolver, sale/line-item RPC.
- **Migration:** external source/account/event mapping with immutable source IDs.
- **Security:** per-business rotating credentials, signature/timestamp validation, replay window, least privilege, dead-letter queue.
- **Events:** `integration_event_received`, `transaction_ingested`, `identity_unmatched`, `integration_failed`.
- **Edge cases:** refund before sale, delayed event, duplicate receipt, unknown customer, branch mapping change, tax rounding.
- **Acceptance:** replay-safe parity with manual Quick Earn and complete reconciliation.
- **Recommended test coverage:** signature/timestamp/replay, mapping drift, duplicate/refund-before-sale, identity ambiguity, financial/loyalty parity, dead-letter recovery and tenant denial.
- **Expected business metric:** automated transaction share, data coverage and weekly staff compliance.
- **Expected customer metric:** earn latency, missing-earn complaints and balance accuracy.

### 4. Real communications worker

- **User problem:** owners must copy phone numbers/messages and contact customers manually.
- **Evidence:** Grow UI explicitly states messaging is not automated; no live marketing provider path was found.
- **Why adoption falls:** the owner still performs the work and Nestly cannot observe exposure.
- **Product behaviour:** owner approves one bounded action; Nestly rechecks consent/preferences/quiet hours/caps, sends, reports delivery truth and retries only retryable failures.
- **Technical approach:** provider adapter behind an outbox worker; immutable attempts/receipts; signed provider callbacks; dead-letter and alerting.
- **Affected components:** Grow UI, notification preferences/outbox, Edge Function/worker, cron/queue, provider secrets, platform alerting.
- **Migration:** add provider-neutral message, recipient, attempt, receipt, suppression and interaction records; existing manual campaigns remain `delivery_unknown`.
- **Security/privacy:** least-data provider payload, encrypted secrets, signature verification, retention, opt-out and cross-tenant isolation.
- **Events:** queued, suppressed, attempted, delivered, failed, interacted, opted_out.
- **Edge cases:** opt-out after approval, expired reward, duplicate callback, cross-outlet duplicate, quiet-hour rollover, provider outage.
- **Acceptance:** holdout never queued; suppressed customer never sent; callback replay safe; UI never equates queue acceptance with delivery.
- **Tests:** provider capture adapter, callback signature/replay, consent race, quiet hours, caps, dead-letter/alert, cross-business denial.
- **Business metric:** recovered customers and net contribution.
- **Customer metric:** delivery relevance, opt-out and complaint rate.

### 5. Product-adoption instrumentation

- **User problem:** Nestly cannot see where owners, staff or customers abandon the product.
- **Evidence:** no complete product analytics/client-error SDK or funnel event taxonomy was found.
- **Why adoption falls:** prioritisation relies on anecdotes and passing tests instead of behavioural evidence.
- **Product behaviour:** every critical milestone emits a documented, privacy-safe, idempotent event.
- **Technical approach:** first-party event collector/table or reviewed analytics provider; server authoritative for economic outcomes, client events only for view/attempt interactions.
- **Affected components:** auth/join, onboarding, programme publishing, Quick Earn, redemption, Grow, billing, release/error telemetry.
- **Migration:** event schema with stable name/version, actor type, pseudonymous IDs, occurred/received timestamps, release identity and bounded properties.
- **Security/privacy:** no raw phone/email/name; role-scoped access; retention/deletion policy; consent where required.
- **Events:** the complete taxonomy in `09-METRICS-AND-PILOT-DESIGN.md`.
- **Edge cases:** offline/late event, duplicate browser retry, clock skew, anonymous-to-known identity transition, deleted account.
- **Acceptance:** funnel queries reproduce known synthetic journeys; duplicates <0.5%; milestone completeness >95%.
- **Tests:** schema validation, replay, identity transition, deletion, cross-tenant report denial, release SHA/error capture.
- **Business metric:** activation, paid conversion and 30/60/90-day SME retention.
- **Customer metric:** join, first earn, redemption and second-purchase funnels.

### 6. Unified Grow onboarding

- **User problem:** an owner sees many submodules and does not understand the whole programme.
- **Evidence:** production v96 exposes fragmented Grow configuration; local v98 adds a unified overview/guided draft.
- **Why adoption falls:** the owner must become a loyalty expert before seeing customer value.
- **Product behaviour:** choose an outcome/template, preview the complete customer journey and economics, publish once, then edit individual parts.
- **Technical approach:** orchestration UI over existing versioned programme/reward/benefit RPCs; one draft ID and explicit per-step server state; no hard reload.
- **Affected components:** Grow page, recommendation drafts, programme/reward publishing, programme media and customer preview.
- **Migration:** preferably none; if atomic publish is absent, add a server-side draft/publish orchestration command with rollback.
- **Security/privacy:** owner/manager permission; branch scope; no silent activation; immutable published version.
- **Events:** setup_started, template_selected, preview_viewed, draft_saved, programme_published, setup_abandoned.
- **Edge cases:** existing live programme, stale draft, partial RPC failure, removed module, branch override, two-tab edit.
- **Acceptance:** first-time owner publishes a safe programme in <15 minutes; no hard refresh; no partial publish; preview matches customer view.
- **Tests:** browser usability at desktop/mobile, stale/replay/failure injection, role/module denial, published-version parity.
- **Business metric:** time to launch and onboarding completion.
- **Customer metric:** first-reward attainability and programme comprehension.

### 7. Mobile frontline shell

- **User problem:** counter staff repeatedly scroll past a large navigation grid on a phone.
- **Evidence:** current responsive CSS transforms the workspace navigation into a grid rather than a counter-specific shell.
- **Why adoption falls:** repeated taps/scrolling compound during queues.
- **Product behaviour:** persistent Quick Earn, scan and appointment actions; all other modules in a permission-aware drawer.
- **Technical approach:** responsive navigation component driven by the existing effective-module/role resolver; preserve current routes and scroll position.
- **Affected components:** workspace layout/CSS, header, route transitions, role capability projection.
- **Migration:** none.
- **Security/privacy:** hiding an action is not authorisation; existing server checks remain mandatory.
- **Events:** counter_action_opened, transaction_started/completed, redemption_scan_started/completed, navigation_abandoned.
- **Edge cases:** restricted front desk, no appointments module, orientation change, keyboard open, slow navigation, notification overlay.
- **Acceptance:** primary counter actions are one tap away; 375/390px no overflow; route changes do not jump to page top; p95 operation <20 seconds.
- **Tests:** owner/manager/front-desk matrices, mobile viewports, keyboard/safe-area, scroll preservation, denied server command.
- **Business metric:** weekly active staff and transaction coverage.
- **Customer metric:** checkout time and redemption success.
