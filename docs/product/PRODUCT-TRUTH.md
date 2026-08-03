# Peekaa product truth

Last consolidated: 2026-08-03

This is the durable statement of confirmed owner decisions. It describes the
intended product, not the current implementation. Implementation and evidence
status live in `../qa/TRACEABILITY-MATRIX.md`.

## Product and audiences

- Owner rebrand decision 2026-08-02: the customer-facing product brand is
  **Peekaa** (spelled with two final “a” characters), the canonical public
  domain is `peekaa.asia`, and the monitored public/commercial mailbox is
  `admin.peekaa@gmail.com`. Historical evidence and internal compatibility
  identifiers may retain Nestly/Frenly wording, but no current customer,
  merchant, store-listing, email-link, share-link, favicon, install icon, splash,
  or public metadata surface may present the retired product brand/domain.
- The contracting legal entity remains **NESTLY TECHNOLOGIES PTE. LTD.** (UEN
  **202634502E**) unless the owner supplies a later legal-entity decision. A
  product rebrand does not rewrite executed agreements or misstate the operator.
- Peekaa serves businesses, their staff, customers, and Peekaa platform staff.
- The customer entry is the default public experience. Business sign-in lives
  at `/business`. The platform administration entry is not promoted publicly.
- The experience must be understandable to a busy, non-technical SME operator
  on first use and usable as a mobile web app before native-store distribution.

## Launch feature freeze and truthfulness

- Owner decision 2026-08-03: the product is feature-frozen for launch. No new
  module, dashboard, destination, workflow, or customer promise may be added
  during launch-readiness work. Work is limited to correctness, stability,
  performance, clarity, and completion of behavior already present in the
  confirmed product scope.
- Every visible dashboard value must come from an identified persistent source
  and use one documented formula, branch scope, time range, Singapore-calendar
  boundary, and inclusion/exclusion policy. A failed, partial, stale, capped, or
  unavailable read must never be displayed as an exact zero or exact complete
  total. Projections appear only with sufficient source data and are labelled as
  projections rather than historical fact.
- A visible action must perform its labelled existing operation exactly once or
  present a truthful disabled/unavailable state. Placeholder, demo, sample,
  coming-soon, fabricated, hard-coded production data, and no-op controls do not
  belong in a launch build.
- If an already-scoped feature lacks the required production-quality behavior,
  complete it without expanding its workflow. If completion depends on an
  unavailable provider, credential, legal decision, or other external input,
  hide the action from ordinary users or expose only an honest unavailable state
  that makes no claim of completion. Historical records and existing customer
  value remain intact.
- Launch-readiness changes must preserve current role, tenant, module, branch,
  ledger, audit, and idempotency boundaries. Reliability or presentation work
  must not broaden authority or introduce a second source of truth.

## Customer identity and programme joining

- A customer joins a business only through a business-issued join QR/link.
- Scanning the QR leads to account creation or sign-in and then automatically
  links the scanned business. The customer must not scan the same code twice.
- An existing customer can scan another participating business QR to add that
  programme. Customers cannot search for and self-link arbitrary businesses.
- A new account with no programme sees a single clear first task: scan a
  participating business's QR. It must not see fabricated programme data.
- Normal customer sign-in is mobile number plus password or a registered
  passkey. OTP is used only for account creation and forgotten-password
  recovery. It must not be spent on normal sign-in.
- Passkey presentation may be conditional on browser/platform support. The UI
  must not promise that a browser will allow a silent biometric prompt where
  platform policy requires user mediation.
- The customer portal is English-only at this stage.

## Customer experience

- Existing customers choose a compact business programme, then see that firm's
  individual programme, points/value, benefits, progress, packages/vouchers,
  visits, transactions, bookings, and relevant actions.
- The programme selector uses compact logo-led cards, up to five per desktop
  row, with a mobile-friendly layout. When a customer has programmes from
  several sectors, the selector groups only those already-linked businesses
  into plain-language categories such as Personal care, Food & drink, and
  Fitness. Categories never create a business relationship or permit arbitrary
  search/self-linking.
- Business logos, programme images, reward images, and enabled catalogue
  content sync from the owner configuration to the customer portal.
- Notification is a header action, not a duplicate dashboard module. Profile is
  a top-right menu, not a primary navigation tab.
- Programme relationship removal is not part of the everyday customer journey.
  Do not show a destructive Disconnect control on the programme page.
- Customer-visible sections disappear when the business has not enabled or
  configured them. The portal must not advertise a missing birthday benefit,
  gift card, booking flow, or other disabled feature.
- Booking actions appear only when that business enables customer booking.
- All visible transaction history includes the business, time, amount,
  relationship/reversal state, and points earned or spent per transaction.
- Purchases and points events live under one clearly labelled **History**
  section. They are supporting detail, not competing top-level programme
  content.
- Each eligible reward has a clear **Redeem now** action beside it. That action
  prepares the pending business-scannable QR; unavailable rewards explain the
  requirement without presenting a dead button.
- A tier/progress card appears only when the programme has a real configured
  tier or measurable milestone. Do not fill an empty tier card with generic
  statements such as "Every visit still counts."
- The primary balance is large enough to scan quickly, but must not overwhelm
  the programme name, reward actions, or progress. Do not repeat the same
  balance in a second metric block.
- The experience should feel rewarding and game-like without hiding financial
  truth: clear progress, milestones, delightful success language, restrained
  sound/haptics with user control, and no false rewards.

## Earning, packages, vouchers, gifts, and redemption

- Customer points and balances must be derived from the same persistent records
  used by the business workspace.
- A customer redemption creates a pending, time-limited QR. Value changes only
  after authorized business staff scan and confirm it in Quick Earn.
- Quick Earn shows a selected customer's owned and eligible packages, vouchers,
  memberships, and pending redemptions. Gift-card issuance, lookup, transfer,
  and redemption are not Quick Earn actions; they remain in the dedicated Gift
  Cards workflow so checkout stays focused. Applying any visible entitlement
  must update the business record and customer portal consistently.
- Gift-card issuance controls appear only when gift-card issuance is enabled.
  Disabling new issuance must not erase or strand valid existing customer value.
- Services support meaningful variants such as Spa 30/60/90 minutes, with their
  own price, duration, availability, and branch applicability.
- Package setup shows individual/list value, selling price, savings amount, and
  savings percentage. Package eligibility must identify the exact service or
  variant covered.
- The owner decides whether purchasing a package earns points. Redeeming a
  prepaid package session does not create a second paid sale.
- Corrections are fast but explicit: show the exact effect, require a
  confirmation, retain an audit relationship, and avoid mandatory essay-length
  justifications.

## Business onboarding and modules

- A business owner may sign in or create the owner identity with email/password
  or Google. Google authentication returns to the canonical Peekaa business
  entry and preserves the self-service onboarding path. A successful Google
  authentication never grants a business role by itself; server-side persona,
  workspace and payment state remain authoritative. Owner clarification
  2026-08-02: ordinary sign-in shows no Terms/Privacy checkbox. Explicit legal
  acceptance appears only while creating a new account, including the Google
  signup entry. If Google sign-in returns an identity with no existing business
  persona, the server rejects that login and the user must return through the
  consent-gated signup path. Google signup is admitted only after consuming a
  short-lived server consent attempt pinned to the exact active Terms and
  Privacy versions and hashes; the acceptance is then retained as private,
  append-only, user-bound evidence before any workspace can be created.
- Browser sessions persist on the user's device and refresh automatically until
  the user explicitly signs out, the provider invalidates/revokes the session,
  or a security-sensitive action ends it. Reloading, closing the tab, installing
  the PWA, or returning on an ordinary later day must not force a fresh login.
- Owner clarification 2026-08-01: the public business signup is self-service.
  A new owner creates and confirms an account, enters the business and sector,
  selects annual or monthly billing plus customer capacity, reviews the exact
  recurring amount, and continues to Stripe Checkout. No super-admin approval
  request is part of this ordinary signup path.
- A self-service workspace is created in a payment-pending state and exposes no
  business data or operational writer until a signed Stripe webhook proves the
  matching snapshotted Price IDs, cadence, customer capacity, exact SGD charge,
  zero GST and zero remaining balance on the subscription's first successful
  payment. Manual platform approval/rejection is unavailable for that
  payment-managed state. A canceled, failed,
  abandoned, forged, replayed, or merely completed Checkout Session cannot open
  the workspace. Provider-confirmed payment opens it idempotently; refresh then
  takes the owner directly into guided setup.
- Assisted sales/platform onboarding may remain for consultant-led firms, but
  it must not intercept or gate the public self-service signup path.
- Super admin owns sector templates. Selecting a sector assigns its cookie-cutter
  module bundle.
- Only super admin can add or remove firm-level or branch-level modules outside
  the sector template. Owners may control staff access only within the firm's
  effective module set.
- Inventory is not part of the default firm experience.
- Customer Intelligence is a Peekaa platform/consulting capability, not a
  self-service owner module. Authorized Peekaa consultants can generate it for
  assigned firms.
- A business can enable or disable catalogue-led Quick Earn. When enabled,
  Quick Earn uses the firm's products, services, packages, and variants rather
  than replacing them with payment-method choices.

## Business operations

- Customer search and tagging support name and phone number so duplicate names
  remain distinguishable.
- The everyday checkout action is labelled **Record sale**. “Quick Earn” is a
  legacy internal name and must not appear in the business workspace.
- Customer lists let an authorised operator show customers whose last valid
  visit was at least 30, 60, or 90 complete Singapore-calendar days ago.
  Customers who have never visited are included and clearly labelled, rather
  than silently omitted.
- A last valid visit is the newest original `counts_as_visit` sale that has not
  been reversed. Canonical SGD 0 package-session usage is a visit; a partial
  refund does not erase the visit; a full sale reversal or restored package
  session does. Revenue residual value is not the visit contract.
- Ordinary customer operations omit gender selection and empty gender copy.
  Historical stored values are retained. Owner clarification 2026-08-02: the
  Performance dashboard may show an aggregate **Recorded gender** demographic
  beside age groups when those historical values exist, must include an
  **Unknown** group, and must never imply that staff need to collect gender.
  Customer profiles explain loyalty in plain language and label the unified
  commercial activity feed **Sales history**.
- Staff are displayed by their working name; email may remain secondary identity
  information but must not be the primary operational label.
- Appointments can be created, viewed, amended, rescheduled, assigned,
  completed, marked no-show, and cancelled according to role.
- The Appointments calendar is an operational writer, not a read-only report:
  an authorized user can select a free time inside a named staff member's
  column to create an appointment with that exact staff/date/time prefilled.
  The two-staff day view must make conflicts, leave, breaks, blocks, and
  available time visually distinct and persist new appointments after refresh.
- Customer feedback is stored once and projects consistently to the business
  workspace after refresh/reconnect. A business may configure its verified
  Google review URL. After any genuine internal rating is saved, the success
  state may offer the same clearly labelled external Google review link.
  Wording may thank a five-star customer warmly, but link access must not depend
  on the score because selective positive-review solicitation is prohibited by
  Google Maps policy. External navigation is always an explicit customer action.
- Navigation must preserve the user's position and state; left navigation must
  not hard-refresh, jump to the top, or show an unexplained blank workspace.
- Owner annotated iPad review 2026-08-02: the business landing destination is
  labelled **Dashboard**, not Home. The branch selector sits with the persistent
  app-bar actions. The dashboard does not repeat Record sale, New appointment,
  customer search, or Grow as four page cards because those actions are already
  in the app bar/navigation. Performance is always visible and cannot be
  collapsed. Its Today/7/30/90/custom range, KPIs and charts form one distinct
  analytical surface below the app bar.
- Every dashboard KPI is a semantic 44px-or-larger control. Activating it opens
  a concise definition, the selected scope/value, and one relevant drill-down.
  **Valid visits** counts only original rows marked as visits that have no
  compensating reversal. Reversal rows and the originals they fully reverse
  remain visible in signed ledger history, but neither is a valid visit.
  Branch-scoped values name the applied branch, while values from
  business-wide readers are labelled business-wide. Edited dates do not relabel
  existing figures until a fresh read succeeds.
  **Customer records with valid visits** means distinct identified customers
  attached to at least one unreversed valid visit in the selected range; gift
  card issuance, other non-visit sales, reversal rows, and fully reversed
  originals do not count. **Inactive customers** means no unreversed valid visit
  for at least 30 complete Singapore-calendar days, including never-visited
  customers. Charts label SGD values as currency; weekday intensity uses green
  for quieter, amber for medium and red for busiest; demographics disclose
  unknown data instead of inventing detail. The earlier services-versus-goods
  request is launch-hidden because current sale-item detail cannot reconcile
  every recorded sale to a trustworthy whole. Dashboard charts may remain
  visible only when their persistent source and complete formula reconcile to
  the displayed total. Report and inactivity failures stay in context with a
  Retry action.
- The Customers directory keeps name/phone duplicate safety, makes the
  30/60/90-day last-visit filter obvious, and displays **Date joined**. Customer
  profiles label the deterministic recommendation **Peekaa's suggestion**,
  state the practical reason/action, show the next expiring points amount/date
  when one exists, and give the Rewards card its own recognisable header.
- Owner analytics include returning-customer count, visit frequency, revenue
  per customer, customer histories, and cautiously labelled projections only
  after sufficient data exists.

## Grow experience

- Grow is introduced through one guided setup and a visual overview of what will
  be created.
- Owner clarification 2026-08-01: the everyday Grow page has one dominant
  starting action, **Set up rewards automatically**. It opens a short popup
  that explains the recommendation in owner language and creates an editable
  draft only after explicit confirmation. Opening or dismissing the popup must
  write nothing, retries must reuse the same request identity, an existing
  draft must never be silently replaced, and publication remains a separate
  protected owner action. The complete Rewards overview appears immediately
  after the starting action; profitability, journey anatomy, optional tools and
  technical editors are secondary disclosures rather than competing starts.
- Owner follow-up 2026-08-02: automatic setup must not make a busy owner click
  through read-only pseudo-steps. With no draft, the everyday action truthfully
  offers to create a recommended rewards draft and requires at most one compact
  review sheet plus one explicit create confirmation. With an existing draft,
  **Continue rewards setup** opens that draft directly in one action and performs
  no recommendation write. The review states exactly what will be created, what
  is not included, which price inputs are used, and that real fulfilment cost
  still requires owner review. Successful creation shows a concise draft-ready
  handoff before the detailed editor. Primary actions remain visible without a
  scroll gesture at 375px portrait and phone landscape; publication stays a
  separate protected owner action.
- The overview explains the whole programme in plain language, shows the
  customer-facing result, and makes each section directly editable.
- The business-owner overview shows every configured reward and birthday
  benefit as an ordered, game-like path: what the customer does, current
  progress unit, what unlocks at each milestone, and what comes next. It must
  not invent a milestone where no rule exists.
- Owner clarification 2026-08-01: that overview is one complete working view,
  not a decorative summary. It shows the published earning model and rate
  (points or stamps), the classic redemption promise when that model is used,
  every configured catalogue reward, and the configured birthday benefit.
  Selecting a specific reward or birthday benefit opens the editor for that
  exact stable record; duplicate names must never route to the wrong editor.
  A paused programme, a future reward, or a reward whose claim window ended is
  labelled with that exact state and is never described as currently earnable
  or unlockable. Published birthday copy is read through a tenant-scoped
  Loyalty-read contract; its private version table remains browser-closed.
- Product/service cost and selling price feed an understandable profitability
  view showing gross profit, margin, estimated reward cost, and the remaining
  contribution after reward. Deterministic template-assisted programme setup must explain its
  assumptions in plain language, use the firm's real catalogue costs/prices,
  and require explicit owner review before saving or publishing.
- Everyday rewards, bring-backs, referrals, memberships, gift cards, and
  advanced rules must not feel like disconnected technical submodules.
- Owner clarification 2026-08-02: Grow is one workspace destination. Its
  overview contains Earn, every reward milestone, Birthday, Bring-back,
  Referrals, Memberships and Gift cards; these are not separate equal-weight
  items in the left navigation. Selecting one row opens that exact submodule in
  the same Grow workspace, and Save/Done returns to the overview with its prior
  position and state preserved. The neutral `#/grow` entry is available when
  the user can read any Grow family; it must not require Loyalty merely to open
  a retention-, referral-, membership- or gift-card entitlement. If an exact
  published reward, Birthday benefit or Bring-back rule is missing from an
  older editable draft, the owner may copy only that stable record into the
  draft under optimistic concurrency. A lost-response retry returns the same
  draft record and never publishes, duplicates or replaces unrelated work.
- Owner screenshot clarification 2026-08-02: an exact Grow deep link is a
  single-task editor, not a long combined configuration page. Selecting Earn
  renders only Earn; selecting one stable reward renders only that reward;
  selecting Birthday renders only Birthday; the same isolation applies to
  Bring-back, Referrals, Memberships and Gift cards. The overview home is hidden
  while an editor is open; an editor is never appended below the overview. No
  adjacent programme form may appear above or below the selected editor. Save/Done returns to the one
  Grow overview; browser Back remains predictable and direct links remain valid.
- Owner production verification clarification 2026-08-02: Grow authority copy
  must describe the user's actual permission. An owner who can manage Loyalty
  and has an editable draft sees `Editable draft`; that state must never be
  labelled `Read only`. A user without Loyalty write authority sees `Read only`
  and receives no write control. When no draft exists, an authorized owner sees
  the explicit create-draft action.
- Every programme has a clear owner-controlled on/off state where that module's
  governing contract permits it. Turning a programme off keeps its draft and
  historical value but removes the inactive programme from new customer-facing
  projections after refresh. Existing customer liabilities and immutable
  history are never erased or stranded by a visibility toggle.
- Recommendations use the firm's actual sector and prices. They state their
  assumptions and permit owner customization beyond a benchmark range.
- English, Simplified Chinese, and Malay are workspace UI choices that translate
  the interface. They are not side-by-side merchant content fields.

## Peekaa platform administration

- Platform roles are Super Admin, Admin, and Sales/Consultant.
- Super Admin can read/write all platform data and configure admin permissions.
- Admin access is module-action configurable by Super Admin.
- Sales/Consultants see firms assigned to or created by them, manage their
  onboarding cases, and generate reports/customer intelligence for those firms.
- Platform users can view firms across branches, drill into one branch, view
  customers in aggregate or by branch, search firms, contact the decision maker,
  manage a streamlined onboarding board, and surface unattended cases.
- Businesses that sign up through the website appear in platform onboarding;
  already onboarded firms appear as won/active rather than disappearing.

## Billing and consultant commission

- The contracting operator is **NESTLY TECHNOLOGIES PTE. LTD.** (Singapore UEN
  **202634502E**). The monitored commercial/privacy mailbox currently supplied
  by the owner is **admin.peekaa@gmail.com**. Formal DPO designation and counsel
  approval remain separate launch gates.
- One launch plan is offered in SGD: **SGD 149 billed monthly** or **SGD 1,188
  billed annually** (SGD 99/month equivalent), with annual selected by default.
  **SGD 168/month** is display-only comparison pricing and must never be sent to
  Stripe as the amount due unless a later explicit owner decision introduces an
  actual billable price at that amount.
- NESTLY TECHNOLOGIES PTE. LTD. is not GST-registered at launch. Peekaa subscription checkout,
  invoices, receipts, platform billing projections, and exports therefore show
  **GST not charged (SGD 0.00)** and the amount due equals the pre-tax recurring
  total. Stripe Tax and automatic tax collection remain disabled, and every
  activated Stripe Price must use explicit `exclusive` tax behavior so a later
  registration cannot silently reinterpret historical prices. Charging GST
  requires verified registration evidence, a new owner decision, an
  independently reviewed catalogue version, and new provider prices; company
  incorporation alone is not GST-registration proof.
- The plan includes 1,000 customer profiles. A merchant chooses capacity in
  1,000-profile increments; each additional 1,000-profile block is SGD 10 per
  month or SGD 120 per annual term. The confirmed capacity and exact recurring
  total must be visible before Stripe Checkout. V124 supports later capacity
  increases through Stripe with provider proration. A prorated change remains
  pending while Stripe reports `pending_update`; it is never presented as
  complete before provider confirmation. Self-service decreases are
  intentionally unavailable through either capacity or cadence commands.
- Individual staff access is included at launch. Peekaa must encourage unique
  staff accounts and least-privilege roles rather than create a pricing reason
  to share credentials. A later pricing change requires a new owner decision
  and migration; legacy seat fields are historical data, not the launch offer.
- Historical subscriptions accepted under the V124 launch terms retain one
  30-day money-back-request
  window. The deadline is the exact timestamp 30 days after that provider
  subscription's earliest successful invoice payment, including an earlier
  matching invoice found by backfill; an unrelated legacy renewal cannot start
  a new window. It is displayed to the owner and never resets after cadence,
  capacity, cancellation or reactivation changes. It is a refund-request
  eligibility policy, not a free trial or an automatic refund; approved refunds
  still follow fraud, chargeback, tax and provider controls.
- Owner decision 2026-08-03 supersedes that launch promise for new business
  subscription purchases accepted under the 2026-08-03 Terms. Those fees are
  non-refundable once payment completes, except where applicable law requires
  a refund or Peekaa expressly agrees otherwise in writing. The change is
  prospective: it must not erase or shorten a request window already earned
  under earlier accepted terms. A paid-invoice webhook still opens the exact
  payment-pending workspace without a management approval step; returning from
  Checkout alone never grants access.
- Complete Stripe subscription snapshots are authoritative for item membership:
  a local capacity item absent from a newer complete snapshot is removed. The
  owner browser reuses one durable request key and command ID for the same
  selection after an ambiguous or lost response, renders terminal failure as
  failure, and never reports it as a submitted success. Each durable command
  snapshots one catalogue row; a later price rollover cannot change provider
  price IDs under the command's Stripe idempotency key. An uncertain increase
  remains recoverable when its webhook has already projected the exact requested
  capacity.
- The checkout overview describes generally included owner/staff/customer
  modules: CRM and QR signup; loyalty points/stamps, reward paths, birthdays and
  referrals; appointments, team scheduling and waitlist; sales/Quick Earn;
  packages, memberships and dedicated gift-card management; customer portal
  wallet/history/redemption; promotions and owner-reviewed template wording assistance;
  feedback and score-independent Google-review handoff; notifications where
  configured; profitability and operational reports; branches, roles and
  permissions; and English, Simplified Chinese and Malay business UI. Payment
  processing fees, usage-priced external messaging, custom integrations,
  platform-only administration and any disabled/unconfigured module are not
  implied to be included or available.
- Peekaa subscription status is automated from the billing provider, including
  paid state and next payment date.
- Overdue businesses receive daily notices from the due date. At 14 days
  overdue, business-owner access is paused with a clear contact for the assigned
  Peekaa representative; customer value and records are not silently deleted.
- Commission excludes GST, refunds, and chargebacks. An onboarding fee, if
  introduced, is commissionable.
- Eligibility begins from onboarding start and requires the responsible staff
  member to remain employed; otherwise commission returns to the company.
- Default senior rates are 30% plus 10% after one completed year, then 15% on
  renewal. Default junior rates are 20% plus 5% after one completed year, then
  5% on renewal. Rates must be super-admin configurable.

## Native store distribution

- Owner clarification 2026-08-01: Peekaa must be prepared for public App Store
  and Google Play distribution, but a generated wrapper or passing browser suite
  is not publication proof.
- The public website remains the only place where a new business owner selects
  a paid Peekaa subscription and continues to Stripe Checkout. Packaged iOS and
  Android builds are purchase-free companion apps: customers may create their
  free account, and already-subscribed owners/staff may sign in and operate, but
  the native build must expose no Stripe Checkout, Billing Portal, paid-plan
  change, external purchase link, or copy that steers a user to another payment
  method. Website billing behavior remains unchanged.
- Every authenticated customer, owner, or staff account has an easy-to-find
  **Delete account** request inside account/profile settings. The destructive
  action explains subscription and legally retained records, requires an
  explicit confirmation, persists one tenant-safe request, and tells the user
  that Peekaa will complete or respond to the request within 30 calendar days.
  Sending an email is not a prerequisite to start the request.
- Universal Links and Android App Links are not accepted until the live
  no-redirect association files contain the exact Apple Team ID and Google Play
  signing-certificate fingerprint. Placeholder teams, certificates and links
  are prohibited.
- Store publication requires the exact signed archive/bundle, current store SDK
  targets, store privacy/data-safety declarations, review credentials, and
  physical iPhone and Android evidence for cold start, authentication, QR,
  denied permissions, offline/reconnect, background/resume and deep links.
- Native promotional/transactional push must not be claimed merely because Web
  Push works in a browser. APNs/FCM credentials, native token persistence,
  consent, provider receipts and physical-device evidence are separate gates.

## Notifications and communications

- Account OTP SMS is limited to creation and forgotten password.
- Basic in-app/Web Push can cover transactional events such as points credited,
  redemption completed, booking changes, package use, and value expiring in
  three days and one day.
- Until an approved WhatsApp Business provider, sender, templates, consent
  policy, and delivery receipts are configured, Appointments may offer only an
  explicit staff-initiated **Message on WhatsApp** action. It opens a prefilled
  appointment summary for a valid customer mobile number and must not claim an
  automatic reminder or a sent/delivered message.
- An owner may publish customer-programme promotion cards made from the
  business's own factual offer, image, dates, terms, and one approved CTA. This
  is in-programme content, not permission to broadcast an unrestricted
  campaign.
- A linked customer may receive one consent-aware in-app promotion prompt and,
  where Web Push permission and delivery configuration exist, one deduplicated
  company-scoped notification for a newly published promotion. Transactional
  expiry reminders remain limited to configured customer value that expires in
  three days and one day. Denied permission, missing delivery configuration,
  duplicate jobs, and expired/inactive offers fail safely without claiming a
  notification was sent.
- The complimentary launch allowance is ten first-published offer slots per
  company through 31 October 2026; unpublishing an offer does not restore its
  slot. V104 offers are company-wide: one published offer is consistent for
  every linked customer and cannot be authored for an individual branch. Two
  currently active offers may be presented at once in the selected customer
  programme. The platform can change an individual company's entitlement later
  without changing the offer records.
- Owners may keep creating and editing unpublished authoring records after the
  allowance is full or the complimentary period ends. First publication after
  that point requires a platform entitlement. Existing publications continue
  to follow their own start/end dates; the window never deletes an offer.
- Fresh promotion authoring and publication use business-owner authority,
  matching the browser surface and owned-media upload path. Super admins may
  inspect promotion state, change a company's launch entitlement, and replay
  an already-recorded exact receipt for support recovery, but cannot originate
  merchant marketing copy or a new publication through these writers.
- Promotion images use UUID object paths in the public customer-media bucket.
  Draft media is not surfaced by Peekaa's customer readers, but it is not
  described as private because possession of its object URL permits access.
- Promotion wording assistance must preserve every merchant-supplied number,
  date, eligibility condition, and term. It must not invent scarcity, prices,
  availability, outcomes, or legal claims. The generated copy remains editable
  and is never published without an explicit owner action.
- Advanced broadcast, paid placement, and push promotional campaigns remain a
  platform-mediated upsell and require appropriate consent and controls.

## Non-negotiable quality rule

No feature is accepted merely because a component, RPC, migration, or button
exists. Acceptance requires realistic end-to-end evidence for every surface
that consumes the value. Peekaa is not described as production-ready while any
required acceptance row is unverified.
