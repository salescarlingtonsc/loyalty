# Frenly vs Flowesce — Product, UI/UX, and Competitive Audit

**Audit date:** 22 July 2026  
**Auditor perspective:** Senior product engineer / product-design reviewer  
**Frenly environment reviewed:** deployed workspace at `loyalty-pi-seven.vercel.app`, current local repository, tests, migrations, and launch evidence  
**Flowesce environment reviewed:** authenticated owner workspace at `app.flowesce.com`, public booking site, and public storefront

## 1. Executive verdict

Frenly is not a weak product hidden behind an average interface. It is a technically serious loyalty, retention, customer-wallet, and financial-integrity platform whose live product does not yet communicate its quality.

Flowesce currently feels like the better product because it presents the entire operating day as one coherent system: calendar, appointments, checkout, clients, inventory, reporting, marketing, website, and customer booking all share one visual grammar and one action model. Frenly has many of the underlying modules, but they often appear as separate database-backed pages rather than one orchestrated experience.

The current overall assessment is:

- **Flowesce product-experience score: 88/100**
- **Frenly live product-experience score: 65/100**
- **Absolute gap: 23 points**
- **Frenly is approximately 74% of the way to Flowesce’s current overall standard.**
- **The live visual/interaction gap is larger: approximately 27 points.**
- **In loyalty configuration safety, financial provenance, tenant isolation design, and cross-business customer identity, Frenly is already equal or potentially ahead.**

The key conclusion is not “copy Flowesce.” The correct strategy is:

1. Reach parity on the daily operating shell and customer-facing journeys.
2. Preserve Frenly’s stronger safety and loyalty architecture.
3. Win on measurable business outcomes: setup speed, repeat visits, customer lifetime value, staff task speed, and trustworthy automation.

“30% better” should mean 30% better outcomes on five high-frequency jobs—not 30% more screens.

## 2. Audit coverage and limits

### Flowesce coverage

Every authenticated navigation destination exposed to the reviewed owner account was opened. Safe, reversible controls were exercised, including calendar views, all report tabs, marketing-builder elements, template selectors, theme switching, filters, global search, account menus, notifications, quick-sale tabs, and appointment/waitlist dialogs.

The following customer paths were also walked without final submission:

- Public service booking through service, stylist, time, and customer-details steps.
- Public product selection, cart, and checkout.
- Desktop and 375 px public-booking layouts.

No sale, refund, appointment, booking, campaign, website publication, notification, or destructive setting was submitted.

### Frenly coverage

Every owner-visible workspace route was opened:

- Home: Dashboard
- Customers: Customers, Loyalty, Retention, Referrals, Memberships, Gift cards
- Operations: Till/Quick Earn, Appointments, Bookings, Waitlist, Sales, Services, Inventory, Packages, Branches
- Insights: Reports, Staff performance, Daily report, P&L, Expenses
- Account: Get started, Settings, Platform, Notifications
- Public booking and booking-management entry point

The Till lookup was safely exercised using an existing customer, stopping before sale confirmation. No customer, sale, appointment, reward, gift card, expense, invite, or configuration was created or changed.

The local repository and its test evidence were inspected. The existing user worktree was not modified except for this new audit report.

## 3. Weighted scorecard

| Dimension | Weight | Flowesce | Frenly live | Assessment |
|---|---:|---:|---:|---|
| Daily operations breadth | 15% | 92 | 70 | Frenly covers the core modules but Flowesce connects them into better staff workflows. |
| Growth and engagement | 15% | 90 | 61 | Frenly has strong loyalty/retention primitives; Flowesce has campaign, journey, referral, review, birthday, and brand execution surfaces. |
| Commerce and payment workflow | 10% | 85 | 48 | Flowesce has a cart-style quick sale, tendering, storefront, orders, deposits, gift cards, and cash drawer. Frenly live Till is amount-led. |
| Customer-facing experience | 12% | 93 | 58 | Flowesce has polished booking and storefront journeys. Frenly has a functional request form and a potentially differentiated wallet, but less orchestration. |
| Visual system and interaction polish | 15% | 92 | 65 | Flowesce is consistent, restrained, layered, and preview-led. Frenly live is clean but flatter and more form/table-led. |
| Information architecture | 10% | 90 | 60 | Flowesce has global actions, grouped navigation, progressive disclosure, and contextual editors. Frenly exposes too much configuration on long pages. |
| Reporting and finance | 8% | 88 | 72 | Frenly has good signed/reversal semantics; Flowesce has broader and more polished reporting, payroll, tax, and cash workflows. |
| Trust, security, and data integrity design | 10% | 74 | 87 | Frenly’s versioned configuration, immutable evidence, idempotency, RLS design, and reversal provenance are a real advantage. Production proof is still incomplete. |
| Mobile, accessibility, and perceived performance | 5% | 82 | 72 | Both show good accessibility intent. Flowesce public mobile is polished; Frenly has strong local accessibility tests but the deployed app showed delays and an authorization error. |
| **Weighted total** | **100%** | **88** | **65** | **23-point gap** |

### Important nuance

If the comparison is narrowed to **loyalty and retention engine integrity**, Frenly is much closer—roughly 85–90% of the way, with several areas ahead. If the comparison is **complete salon/business operating system plus presentation quality**, Frenly is approximately 65–70% of the way.

## 4. Why Flowesce feels better immediately

Flowesce’s advantage is not one beautiful dashboard. It is the repetition of good decisions across almost every screen.

### 4.1 One coherent visual language

Flowesce consistently uses:

- Warm off-white surfaces, restrained chocolate/taupe accents, fine borders, and subtle depth.
- A deliberate serif brand flourish paired with readable interface typography.
- Consistent card radii, table density, icon treatment, spacing, and page headers.
- Calm empty states with useful guidance rather than bare “no data” messages.
- High-quality dark mode that was consistent across the shell.

Frenly has a credible warm-coral token system in the local branch, but the deployed experience does not consistently reach that standard. It still reads as a collection of functional admin views.

### 4.2 Strong action hierarchy

Flowesce’s top bar exposes the actions used all day:

- Global search / command palette
- Quick sale
- New appointment
- Waitlist
- Notifications
- Theme and account controls

Frenly relies more heavily on page navigation. The user must first know where an action belongs, navigate there, then find the form.

### 4.3 Progressive disclosure

Flowesce keeps the first view legible and opens complexity when needed:

- Dialogs for new appointments, quick sale, bundles, packages, and feedback
- Tabs for dense reports and settings
- Detail screens for services, staff, branches, and orders
- Guided builders for website, campaigns, journeys, forms, and promotions

Frenly frequently places creation forms, settings, explanatory text, tables, and secondary actions together. The Settings page is the clearest example: workspace identity, modules, QR, staff invitations, imports, custom fields, isolation copy, and commission configuration coexist in one long surface with multiple indistinguishable Save buttons.

### 4.4 Connected journeys

Flowesce makes adjacent objects feel related:

- A service links to staff, branches, resources, forms, deposits, variants, commission, and inventory.
- An appointment connects client, service, staff, time, deposit, status, policy, reminder, and transaction.
- Quick sale combines services, retail, packages, tips, payment tender, and gift cards in one cart.
- Website, storefront, booking, marketing, referrals, reviews, and brand settings share the same customer identity.

Frenly has many of the same nouns but fewer complete “job” journeys.

### 4.5 Preview before commitment

Flowesce repeatedly lets the user see the outcome before publishing:

- Eight website templates
- Desktop/mobile campaign preview
- Live form preview
- Booking summary before confirmation
- Promotion help and scope explanation
- Brand controls reflected in customer-facing surfaces

Frenly’s strongest versioned-draft mechanics are safer than Flowesce’s in several areas, but the presentation of those drafts is more technical and less visual.

## 5. Detailed feature comparison

| Area | Flowesce | Frenly | Gap / opportunity |
|---|---|---|---|
| App shell | Grouped rail, global actions, search, theme, configurable feature visibility | Grouped rail, account and notification menus | Add global search/actions, recents, keyboard command palette, saved feature visibility, and unified contextual headers. |
| Dashboard | Operational KPIs, timeline, charts, upcoming work, stock and deposit exceptions | Date/branch filters, visits, revenue, customer metrics, charts | Reframe around “needs attention now,” not only historical reporting. Add tasks, alerts, next actions, and drill-through. |
| Calendar | Day/week/month, staff filter, status/staff coloring, inline creation | List/week plus local v47/v48 calendar work | Ship the newer local calendar, then add drag/reschedule, capacity/resource context, availability, and conflict resolution. |
| Appointments | Rich filters, staff/branch/date scope, confirmations, detailed service scheduling | Functional booking form and appointment status actions | Use a detail drawer, clearer status timeline, customer context, reminders, payment/deposit state, and audit history. |
| Booking requests | Dedicated cancel/reschedule request queues and decisions | Request inbox, auto-approval settings, convert/decline | Good foundation; separate salon/service bookings from generic table reservations and improve decision context. |
| Public booking | Four-step service → stylist → time → details journey with real availability and summary | One long request form; team confirms later | Largest customer-experience gap. Add guided steps, availability, staff choice, policy summary, progress, and confirmation state. |
| Booking management | Customer-facing policies and controlled change requests | Opaque management-code entry; strong security intention | Keep token security; redesign the customer management page and communication lifecycle. |
| Waitlist | Walk-in and online queues | Simple request form | Add ranked queue, promised window, service/staff constraints, notify/seat/book actions, and conversion metrics. |
| Clients | Search, filters, sort, import/export, detailed records | Search, pagination, import/export, customer detail | Frenly should create a true Customer 360: next best action, timeline, preferences, visits, spend, balances, memberships, packages, referrals, and consent. |
| Loyalty | Growth plan feature with earn/redeem mechanics | Versioned programs, points/stamps, tiers, expiry, rewards, draft/publish | Frenly is stronger architecturally. Improve visual explanation, simulations, preview, and impact estimates. |
| Retention | Journeys and marketing tools | Versioned retention rules, recommendation drafts, immutable history | This can become Frenly’s moat. Turn technical rules into goal-led playbooks with forecasts and measured lift. |
| Referrals | Two-sided credits, minimum spend, expiry, activity | Primarily one-sided referrer reward | Add advocate and friend rewards, fraud limits, channel sharing, attribution, cost cap, and cohort performance. |
| Memberships | Plan management tied into operations | Plan creation/enrolment, recurring credit drops, renewals | Add payment lifecycle, pause/cancel, failed renewal, customer self-service, entitlement clarity, and revenue recognition. |
| Gift cards | Sell, configure online amounts/expiry/terms, list and redeem | Issue/redeem into customer credit | Fix the live permission defect first. Add storefront purchase, branded delivery, liability reporting, transfer/reissue controls, and clearer separation from loyalty credit. |
| Services | Detail pages with variants, deposits, resources, forms, inventory, branch/staff settings | Add/import/disable, price/duration, bundles/resources/product links | Split list and detail. Add variants, buffers, tax, deposits, policy, availability, images, categories, and contextual previews. |
| Resources | Rooms, chairs, equipment, shared/branch constraints | Basic resources in Services | Promote resources into scheduling capacity and conflict resolution. |
| Inventory | Stock, committed units, threshold, expiry, cost, price, supplier, bulk adjust | Products, receiving batches, FEFO auto-deduct | Frenly’s FEFO is strong. Add purchasing, supplier/order workflow, committed stock, valuation, expiry alerts, and retail/catalog presentation. |
| Packages/bundles | Ordered bundles, credit packages, eligibility, expiry | Service packages and session balances | Add configurable sequence, pooled/fixed services, transfer/freeze, customer self-service, and deferred-revenue reporting. |
| Till / quick sale | Cart with client/staff, services, retail, packages, tips, cash/card/bank/other/gift card | Deployed Till: phone → customer → amount; local branch has a richer Quick Earn and tender selection | Ship local improvements, then build a real cart. Keep a one-tap “Quick Earn” mode for low-literacy/frontline use. |
| Transactions | Unified ledger, filters, net revenue, refunds | Sales ledger with explicit reversal provenance | Frenly’s correction safety is superior. Add receipt view, tender reconciliation, permissioned refund UX, and human-readable resolution paths. |
| Cash drawer | Open/expected/actual, pay-in/out, close count | Missing | Required for counter businesses if Frenly records cash tender. |
| Storefront | Products, categories, pickup/shipping, instructions, reminders | Missing | Do not build first. Validate merchant demand after booking, checkout, and retention are excellent. |
| Orders | Pending, confirmed, fulfilled queues | Missing | Build only with storefront or third-party order integration. |
| Expenses | Multi-currency expense records | Expense entry feeding P&L | Improve categorization, receipt attachment, recurring expenses, supplier linkage, tax, and approval. |
| Reports | Broad operational, service, commission, tips, tax, cancellations, inventory, credits, bundle views | Reports, staff performance, daily report, P&L | Frenly’s signed reversal semantics are excellent; add richer visual drill-down, saved views, comparisons, scheduled delivery, and commentary. |
| Payroll | Commission payout and hours exports, Talenox CSV | Staff performance and frozen commission | Add approval periods, payout state, export integrations, and audit reconciliation. |
| Staff | Profile, branches, services, hours, commission, leave, clock, metrics | Team permissions, module access, commission settings | Add staff workspace, availability, leave, time tracking, targets, permissions templates, and personal dashboard. |
| Branches | Hours, holidays, closures, breaks, tax overrides | Branches and branch visibility | Add operating calendars, closures, branch-specific pricing/policies/availability, and comparison views. |
| Website builder | Eight polished templates, content blocks, service/team/contact/review/FAQ/map/store blocks | Missing | Not a near-term parity requirement unless Frenly positions as an all-in-one website platform. Integrate first; build later only with demand. |
| Email marketing | Brand controls, send log, birthday automation, campaign templates, drag/drop builder, segments | Missing as an operational campaign surface | Build a retention-first campaign composer after provider, consent, suppression, and observability are production-proven. |
| Journeys | Visual workflow drafts; live activation is plan-gated | Retention rules and recommendation drafts | Frenly can leapfrog by combining explainable recommendations, approval, holdout groups, and real incremental-lift measurement. |
| Reviews/feedback | Positive routing to public reviews; negative private feedback | Missing | Add post-visit feedback, service recovery, review requests, and attribution. Avoid review gating that violates platform rules. |
| Promotions | Percent/fixed, scope, code/auto apply, dates, caps, minimum spend | Retention/loyalty rewards but no equivalent promotion surface | Add a unified incentive engine so discounts, loyalty, referrals, birthday, and retention cannot stack unpredictably. |
| Forms | Intake, medical/allergy, photo/treatment templates, signatures | Custom customer fields | Add form templates, pre-visit completion, consent/versioning, attachment security, and staff review. |
| Policies | Presets, cutoffs, fees, card-on-file and payment instructions | One booking-policy text field | Add structured policy rules, customer preview, version history, acknowledgment, and exception audit. |
| Payments | Stripe for Singapore, deposits, no-show/storefront cards | Manual sale/payment-state tracking; production payment model still blocked | Decide and document the payment product boundary. If integrating, build webhooks, reconciliation, failures, refunds, and truthful customer messaging. |
| Messaging | Email works; SMS/WhatsApp explicitly “on the way” | Customer notification architecture exists; provider operations are not production-proven | Frenly can win in Southeast Asia by shipping reliable WhatsApp/SMS with consent, quiet hours, templates, retries, and delivery observability. |
| Integrations | Google Calendar one-way, Shopify/CSV imports, embeds, domains, sending domain | CSV imports, QR, booking/join links | Add calendar sync, accounting/payroll, messaging, payment, and commerce integrations based on target vertical. |
| Imports | Shopify and CSV for major entities | Strong staged CSV/import-job foundation | Frenly can beat Flowesce with dry-run validation, mappings, rollback, deduplication policy, and data-quality reporting. |
| Customer wallet | Conventional single-business client portal | Cross-business My Frenly architecture, separated balances, appointments, packages, memberships, inbox, birthday participation | Major Frenly differentiator. It needs consumer-grade visual design, simple onboarding, merchant discovery controls, and a clear privacy story. |

## 6. Critical Frenly findings

### P0 — Live Gift Cards authorization failure

The deployed workspace emitted:

> `permission denied for table gift_cards`

It appeared as both an alert and status message and remained visible while navigating. The live Gift Cards surface calls the bounded `staff_list_gift_cards` RPC, so this likely indicates a deployed migration/grant mismatch or a live build/backend version mismatch—not merely a missing empty state.

Required closure:

1. Reproduce with owner and restricted staff accounts.
2. Capture the exact network call, function signature, database error, and active migration/version.
3. Verify the deployed function grants, RLS policies, and internal table access.
4. Add a deployment smoke test that opens every enabled module under each canonical role.
5. Do not hide the error with friendlier copy until the permission contract is correct.

### P0 — Release drift between local and deployed UI

The local `app/index.html` describes “Frenly design system v2” and contains a richer **Quick Earn** flow with:

- Branch handling
- Amount paid
- Explicit Cash/Card/PayNow/Other tender selection
- Safer idempotent submission

The deployed app presented an older **Till** experience with only customer, amount, and confirmation. This is direct evidence that product/design review of the repository is not equivalent to product review of what customers use.

Required closure:

- Add a visible build identifier and release timestamp in Platform/About.
- Make the deployed artifact immutable and attach its hash to release evidence.
- Run route-level production smoke tests against that exact artifact.
- Establish one promotion path; prevent local, staging, and production schemas/UI from drifting independently.

### P0 — Production readiness is explicitly blocked

`docs/launch/launch-blockers.json` contains **17 P0 blockers**, all marked `BLOCKED`. They cover cutover parity, public abuse controls, booking tokens, RLS/grants, financial reversal, reporting scale, PDPA operations, authentication email, notifications, payments, backup/rollback, observability, Singapore time, target runtime, credential rotation, post-cutover smoke, and release build proof.

The repository is correct to fail closed. These are not optional polish tasks. Frenly should not claim production readiness until each blocker has hashed production evidence and independent review.

### P1 — Public booking is a request form, not a booking experience

The Frenly portal needed roughly five seconds before meaningful content appeared during the audit. It then rendered a single long form with service, contact details, party size, desired date/time, notes, marketing consent, and “Request booking.” It does not provide live availability, staff choice, step progress, or a strong confirmation preview.

The copy “Signed in as staff” also appeared on the customer-facing portal because the browser already had a staff session. That is technically truthful but contextually confusing and harms customer trust.

### P1 — Daily checkout is underpowered in the deployed product

Flowesce’s quick sale behaves like a point-of-sale cart. Frenly’s deployed Till behaves like a loyalty earn recorder. That distinction is acceptable only if Frenly explicitly positions itself as an overlay rather than the system of record. The current broader operations/reporting footprint implies a system-of-record ambition, so the mismatch is confusing.

### P1 — Industry abstraction leaks into the user experience

The same Bookings page combines service appointments with restaurant-style party size/table/general visits. Cross-industry support is strategically valuable, but presenting every industry concept in one page creates ambiguity. Industry adapters should share an engine while exposing industry-specific language and workflows.

### P1 — Settings has excessive cognitive load

The owner Settings route combines too many concerns and many Save actions. Users cannot easily predict scope, consequence, or whether a change was saved. Split it into:

- Workspace and brand
- Modules and plan
- Team and permissions
- Customer data and fields
- Booking and availability
- Loyalty and retention defaults
- Payments and finance
- Notifications and integrations
- Data import/export and privacy

### P1 — Observability is visible only as raw errors

Both apps showed operational weaknesses:

- Frenly exposed a database permission error directly in the UI.
- Flowesce emitted repeated chart container warnings with width/height `-1` and showed several hydration delays.

Frenly can outperform here by making errors observable to operators while giving staff contextual, recoverable messages.

## 7. Implementation assessment of Frenly

### Strengths

- 366 of 367 local Node tests passed during this audit.
- The single test failure was a fail-closed environment requirement: `EXPECTED_SUPABASE_PROJECT_REF` was unset, while the validator required `gadpooereceldfpfxsod`.
- The repository has unusually strong tests for RLS, RPC grants, idempotency, immutable configuration, reversal provenance, concurrency, Singapore time, pagination, wallet privacy, and accessibility.
- The UI includes skip navigation, route focus, live announcements, dialog focus trapping, reduced-motion support, 44 px targets, responsive table enhancement, loading states, retry states, and semantic controls.
- Loyalty and retention configurations are versioned and published deliberately.
- Financial corrections preserve provenance rather than silently editing history.
- Customer balances remain separated by business in the wallet architecture.

### Architectural constraints

The main SPA is a **5,909-line `app/index.html`**. Static inspection found approximately:

- 879 function/arrow-function occurrences
- 225 `innerHTML` assignments
- 212 direct `onclick` assignments
- 150 direct Supabase table-query calls
- 116 RPC calls

There is a small, useful `customer-ui.js` primitive layer, but most routes, data access, state, markup, events, and business copy still live in one file with global mutable state.

This does not automatically make the app insecure or slow. It does create four predictable problems:

1. Visual inconsistency is cheap to introduce and expensive to remove.
2. One route change can regress unrelated routes.
3. Designers and engineers cannot review components in isolation.
4. Product velocity drops as every new workflow adds more branching to one file.

### Recommended architecture evolution

Do not rewrite the app in one step. Use an incremental extraction:

1. `styles/tokens.css`, `styles/components.css`, `styles/routes/*.css`
2. `ui/` primitives: page shell, header, card, table, form field, dialog, drawer, command menu, empty/loading/error states
3. `routes/<route>/view.js` and `routes/<route>/controller.js`
4. `data/` repositories that are the only browser callers of Supabase
5. Typed request/response contracts generated or checked against database functions
6. Route-level error boundaries and telemetry
7. Playwright task tests plus screenshot regression for desktop and 390 px mobile

Vite plus TypeScript is sufficient; adopting a large framework is not itself a UX strategy. The key is modular boundaries, reusable interaction patterns, and visual review.

## 8. Root causes of the gap

### Root cause 1: Product thesis is not explicit

Flowesce is clearly a salon operating system. Frenly currently spans loyalty overlay, POS-lite, appointment system, inventory, finance, and multi-business customer wallet. Without a clear primary job, every module competes for navigation and development priority.

Decision required: Frenly should position as either:

- a loyalty/retention intelligence layer that integrates with existing POS/booking systems, or
- a complete operating system for a tightly chosen vertical.

Trying to be a generic operating system for every industry will make Flowesce’s vertical depth hard to match.

### Root cause 2: Back-end maturity is ahead of product composition

Frenly has built difficult invisible capabilities—RLS, idempotency, immutable ledgers, configuration history, recommendation drafts—but has not invested equally in the surfaces that explain and connect them.

### Root cause 3: Release discipline is weaker than local implementation quality

The live/local Quick Earn mismatch and Gift Cards error show that shipping and proving one coherent artifact is now more urgent than adding more local capability.

### Root cause 4: Pages are organized by entities, not staff jobs

The sidebar names data domains. The best competitor flows begin with outcomes: sell, book, serve, follow up, close the day, and grow repeat visits.

### Root cause 5: No measured design-quality gate

Frenly has accessibility tests, which is excellent. It now needs equivalent gates for visual hierarchy and task completion:

- approved reference screenshots
- spacing/type/token checks
- empty/loading/error-state coverage
- keyboard and mobile task flows
- interaction latency budgets
- copy and terminology review

## 9. What to build—and what not to build

### Build first

1. One verified production artifact and zero authorization errors.
2. New app shell with global search and global actions.
3. Consumer-grade public booking.
4. Customer 360 and next-best-action view.
5. Rich Quick Earn / quick sale with a deliberate “simple mode.”
6. Shipped calendar/detail/reschedule work already present locally.
7. Reliable notifications and communication history.
8. Goal-led retention playbooks with measured results.

### Do not build first

- A full website builder
- A generic storefront and shipping engine
- Native mobile apps
- A huge template marketplace
- Every Flowesce payroll integration

Those can consume months without strengthening Frenly’s core differentiation.

## 10. Plan to close the gap entirely

Assumption: one product designer, two front-end/product engineers, two backend/platform engineers, and part-time QA/product leadership. A smaller team should extend the calendar rather than cut verification.

### Phase 0 — Stabilize and establish truth (1–2 weeks)

- Fix and independently verify the live Gift Cards permission failure.
- Identify the exact live build and database migration state.
- Add build SHA/version to the UI and telemetry.
- Run the full 17-blocker production-evidence plan; do not convert “implemented locally” into “verified” without evidence.
- Capture baseline task timings and funnel events.
- Define the product thesis and target vertical/ICP.

**Exit criteria:** zero known authorization errors, one immutable release artifact, route smoke tests for every role, agreed product positioning, and baseline metrics.

### Phase 1 — Design foundation and app shell (4–6 weeks)

- Extract design tokens and core UI primitives from the monolith.
- Define page templates for list, detail, editor, builder, and operational queue.
- Introduce global search, Quick Earn, appointment, customer, and waitlist actions.
- Reorganize navigation around jobs:
  - Home
  - Serve & sell
  - Customers
  - Grow
  - Money
  - Settings
- Create consistent skeleton, empty, error, success, permission, and destructive-confirmation states.
- Add compact/comfortable table density and saved user preferences.
- Establish screenshot regression for key desktop/mobile routes.

**Exit criteria:** 100% of priority routes use the same shell and primitives; no route-specific ad hoc header/button/table styling; visual QA is part of CI.

### Phase 2 — Daily operations parity (6–8 weeks)

- Ship the newer Quick Earn branch/tender workflow.
- Add cart mode for services, products, packages, discounts, tips, gift card, and split/partial policy if supported.
- Ship calendar detail and safe reschedule work.
- Add appointment detail drawer with client, service, notes, policy, reminders, payment, and audit trail.
- Create Customer 360 with one timeline and one “recommended next action.”
- Upgrade waitlist into a conversion queue.
- Add close-day reconciliation if cash tender is retained.

**Exit criteria:** a trained staff member can book, find a customer, record a purchase, redeem a reward, change an appointment, and close the day without navigating through disconnected forms.

### Phase 3 — Customer experience and growth parity (8–12 weeks)

- Replace the public booking form with a guided availability-led journey.
- Redesign My Frenly as a consumer product, not an admin derivative.
- Add messaging provider operations, consent, retries, delivery events, suppression, quiet hours, and failure recovery.
- Add two-sided referrals, birthdays, feedback/reviews, and service recovery.
- Build a campaign composer focused on retention use cases, not a generic email designer.
- Add cohort and campaign outcome reporting.

**Exit criteria:** booking and wallet are consumer-grade; every automated message is consented, observable, and attributable; repeat-visit campaigns can be launched and measured end to end.

### Phase 4 — Become 30% better (12–16 weeks)

- Turn recommendation drafts into explainable, goal-led retention playbooks.
- Add holdout groups and incremental-lift measurement so Frenly proves what caused repeat revenue.
- Give each recommendation predicted upside, cost cap, confidence, affected audience, and rollback.
- Offer a cross-business customer wallet without merging balances or leaking merchant data.
- Add integrations based on target merchants: WhatsApp, Google Calendar, payments, accounting, and selected POS/booking platforms.
- Create proactive exception management: expiring points, stock risk, lapsed VIP, no-show risk, failed renewal, unclaimed referral, and unclosed drawer.

**Exit criteria:** Frenly produces demonstrably better retention outcomes and faster frontline work than Flowesce, not merely feature parity.

### Realistic timing

- **Visible UI parity:** 8–10 weeks
- **Daily-workflow parity:** 3–4 months
- **Growth/customer-experience parity:** 5–7 months
- **Full focused roadmap with differentiation:** 7–9 months with the assumed team
- **With two or three engineers total:** approximately 9–12 months

## 11. Defining “30% better” precisely

Flowesce’s broad feature score is already high, so multiplying its 88/100 by 1.30 is meaningless. Frenly should beat Flowesce by 30% on measurable jobs while reaching table-stakes parity elsewhere.

| Outcome | Frenly target |
|---|---:|
| Time from signup to first live loyalty programme | ≤ 15 minutes |
| Time for frontline customer lookup + earn | ≤ 10 seconds, ≤ 5 purposeful taps after lookup |
| Public booking completion time | ≤ 45 seconds for a returning customer |
| Public booking abandonment | 30% lower than measured Flowesce benchmark or matched cohort baseline |
| Time from retention insight to approved campaign | ≤ 3 minutes |
| Staff correction/reversal resolution time | 30% faster with 100% preserved provenance |
| Permission or cross-tenant errors in production | 0 |
| Route meaningful-content p75 | < 1.5 seconds on target mobile network |
| Key-task success rate | ≥ 95% without assistance |
| Repeat-visit lift for activated playbooks | ≥ 30% relative lift against a holdout or matched control where statistically valid |
| Support contacts per 100 active businesses | 30% below baseline |

The product should report these internally. If Frenly cannot measure the improvement, it cannot credibly claim to be 30% better.

## 12. The defensible Frenly advantage

Flowesce can copy colors, cards, loyalty tiers, and email templates. It is much harder to copy a trusted retention operating model.

Frenly’s strongest potential position is:

> **The loyalty and retention operating system that tells local businesses exactly who to bring back, what to offer, why it should work, what it will cost, and whether it actually caused the return—without compromising customer trust.**

That position is supported by assets Frenly already has:

- Versioned loyalty and retention configuration
- Explicit draft and publish workflow
- Immutable historical evidence
- Idempotent financial operations
- Reversal provenance
- Branch-aware permissions
- Cross-business wallet with separated balances
- Consent and customer-inbox foundations
- Recommendation-draft foundation

The UI must make those strengths obvious in plain language.

## 13. Flowesce weaknesses Frenly can exploit

- SMS and WhatsApp were still marked as upcoming.
- Stripe payment support was presented as Singapore-only.
- No native admin mobile app was evident.
- Several authenticated pages took noticeable time to hydrate.
- Chart rendering produced repeated width/height `-1` console warnings.
- The navigation is broad enough to become overwhelming for small operators.
- Some import behavior appeared inconsistent: Shopify customer import described email deduplication, while generic client import warned that email collisions were not deduplicated.
- Flowesce’s breadth is salon-specific; Frenly can serve adjacent verticals if it hides irrelevant industry concepts.

Frenly should not market these as attacks. Use them to set priorities: reliable SEA messaging, faster task performance, simpler role-specific workspaces, explainable retention, and provable data integrity.

## 14. Recommended product principles

1. **One primary action per screen.** Secondary operations belong in drawers, menus, or detail views.
2. **Show the business outcome first.** “12 customers likely to lapse” is stronger than “Retention rule configuration.”
3. **Progressive disclosure by default.** Simple mode first; expert controls remain available.
4. **Every automation is explainable, previewable, reversible, and measurable.**
5. **Industry-specific language on top of shared engines.** Never show restaurant vocabulary to a salon unless enabled.
6. **Customer-facing surfaces meet consumer-app standards.** They should not look like public versions of admin forms.
7. **Production truth beats local sophistication.** A feature exists only when the reviewed artifact is deployed, observable, and verified.
8. **Trust is visible.** Translate idempotency, versioning, consent, and provenance into reassuring product language.

## 15. Immediate next ten actions

1. Freeze new breadth work until the live Gift Cards failure and release drift are explained.
2. Add build SHA/version and environment visibility.
3. Complete a live role-by-route smoke matrix.
4. Decide whether Frenly is a retention layer or a vertical operating system.
5. Design the new shell and five canonical page patterns in Figma or code prototypes.
6. Ship local Quick Earn/calendar improvements through the verified release path.
7. Prototype the new four-step public booking and test it with five real operators/customers.
8. Build the Customer 360 “next best action” view.
9. Select and production-prove the messaging operating model.
10. Instrument the 30%-better outcome scorecard before claiming competitive superiority.

## Final assessment

Frenly is **closer technically than it looks and farther experientially than the feature list suggests**.

The backend and test posture show careful engineering. The live product presentation, release coherence, workflow composition, and customer-facing experiences are not yet at Flowesce’s standard. Fixing only colors and shadows would produce a prettier version of the same gap.

The full closure path is to ship one verified product, reorganize it around daily jobs, make the customer surfaces consumer-grade, and turn Frenly’s retention integrity into a visible business-outcome advantage. With a focused five-person product team, visible parity is achievable in roughly 8–10 weeks and a credible 30%-better differentiated product in approximately 7–9 months.
