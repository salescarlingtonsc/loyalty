# Nestly product truth

Last consolidated: 2026-07-29

This is the durable statement of confirmed owner decisions. It describes the
intended product, not the current implementation. Implementation and evidence
status live in `../qa/TRACEABILITY-MATRIX.md`.

## Product and audiences

- The brand is **Nestly** and the public domain is `nestly.asia`.
- Nestly serves businesses, their staff, customers, and Nestly platform staff.
- The customer entry is the default public experience. Business sign-in lives
  at `/business`. The platform administration entry is not promoted publicly.
- The experience must be understandable to a busy, non-technical SME operator
  on first use and usable as a mobile web app before native-store distribution.

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
  row, with a mobile-friendly layout.
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
  memberships, gift cards, and pending redemptions. Applying an entitlement
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

- A firm requests onboarding; a super admin must approve it before an owner can
  create or activate the business account.
- Super admin owns sector templates. Selecting a sector assigns its cookie-cutter
  module bundle.
- Only super admin can add or remove firm-level or branch-level modules outside
  the sector template. Owners may control staff access only within the firm's
  effective module set.
- Inventory is not part of the default firm experience.
- Customer Intelligence is a Nestly platform/consulting capability, not a
  self-service owner module. Authorized Nestly consultants can generate it for
  assigned firms.
- A business can enable or disable catalogue-led Quick Earn. When enabled,
  Quick Earn uses the firm's products, services, packages, and variants rather
  than replacing them with payment-method choices.

## Business operations

- Customer search and tagging support name and phone number so duplicate names
  remain distinguishable.
- Staff are displayed by their working name; email may remain secondary identity
  information but must not be the primary operational label.
- Appointments can be created, viewed, amended, rescheduled, assigned,
  completed, marked no-show, and cancelled according to role.
- Navigation must preserve the user's position and state; left navigation must
  not hard-refresh, jump to the top, or show an unexplained blank workspace.
- Owner analytics include returning-customer count, visit frequency, revenue
  per customer, customer histories, and cautiously labelled projections only
  after sufficient data exists.

## Grow experience

- Grow is introduced through one guided setup and a visual overview of what will
  be created.
- The overview explains the whole programme in plain language, shows the
  customer-facing result, and makes each section directly editable.
- Everyday rewards, bring-backs, referrals, memberships, gift cards, and
  advanced rules must not feel like disconnected technical submodules.
- Recommendations use the firm's actual sector and prices. They state their
  assumptions and permit owner customization beyond a benchmark range.
- English, Simplified Chinese, and Malay are workspace UI choices that translate
  the interface. They are not side-by-side merchant content fields.

## Nestly platform administration

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

- Nestly subscription status is automated from the billing provider, including
  paid state and next payment date.
- Overdue businesses receive daily notices from the due date. At 14 days
  overdue, business-owner access is paused with a clear contact for the assigned
  Nestly representative; customer value and records are not silently deleted.
- Commission excludes GST, refunds, and chargebacks. An onboarding fee, if
  introduced, is commissionable.
- Eligibility begins from onboarding start and requires the responsible staff
  member to remain employed; otherwise commission returns to the company.
- Default senior rates are 30% plus 10% after one completed year, then 15% on
  renewal. Default junior rates are 20% plus 5% after one completed year, then
  5% on renewal. Rates must be super-admin configurable.

## Notifications and communications

- Account OTP SMS is limited to creation and forgotten password.
- Basic in-app/Web Push can cover transactional events such as points credited,
  redemption completed, booking changes, package use, and value expiring in
  three days and one day.
- Advanced promotional campaigns are a platform-mediated upsell and require
  appropriate consent and controls; firms do not receive unrestricted campaign
  access at launch.

## Non-negotiable quality rule

No feature is accepted merely because a component, RPC, migration, or button
exists. Acceptance requires realistic end-to-end evidence for every surface
that consumes the value. Nestly is not described as production-ready while any
required acceptance row is unverified.
