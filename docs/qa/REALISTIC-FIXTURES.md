# Realistic acceptance fixtures

These fixtures are synthetic and reusable. They are designed to reveal
sector-, branch-, role-, price-, and entitlement-specific failures. Never
replace them with real customer PII.

## `SPA-GLOW` — Glow Atelier

Sector: Facial / Spa

Branches:

- Orchard — all core modules enabled.
- Tampines — bookings enabled, gift-card issuance disabled.

Roles:

- Owner: Olivia Tan
- Google self-service owner: Sofia Ng, synthetic identity
  `qa.v135.google.owner@peekaa.invalid`
- Manager: Maya Lim
- Front desk: Farah Noor
- Service staff: Chen Wei, Aisha Rahman

Catalogue:

| Service/variant | Duration | Price |
| --- | ---: | ---: |
| Express facial | 30 min | SGD 45 |
| Spa ritual | 30 min | SGD 40 |
| Spa ritual | 60 min | SGD 60 |
| Spa ritual | 90 min | SGD 85 |
| Glow serum (retail) | N/A | SGD 68 selling price / SGD 24 product cost |

Packages:

- **5x Spa 60** — list value SGD 300, selling price SGD 270, savings SGD 30
  (10%), valid only for the 60-minute variant, owner-controlled purchase
  points.
- **3x Express facial** — list value SGD 135, selling price SGD 120, branch
  restricted to Orchard.

Configuration cases:

- gift-card issuance off, with one existing valid gift-card liability;
- customer booking on at Orchard and off in an alternate run;
- package purchase points on, then off;
- one firm-level module override and one Tampines branch override;
- logo upload success, replacement, invalid type, and denied-role attempts.
- Orchard staff availability: Chen Wei works 09:00–18:00, Aisha Rahman works
  10:00–19:00, the branch has a 12:30–13:30 break, and Chen has one
  **Supplier training** block on 31 July 2026 from 14:00–15:00 Singapore time.
  Keep one adjacent 15:00 appointment and use Spa Ritual 60 with configured
  before/after buffers to prove a block suppresses every overlapping start
  without hiding Aisha's availability.
- Appointment completion truth: Olivia completes `CUS-MEI`'s booked SGD 60
  Spa ritual 60 at Orchard. With exact-branch Loyalty `rw`, one linked sale and
  one +600 earn persist and all customer-safe wallet/summary/history readers
  agree after refresh. The same status call replays without duplication.
  Repeat with firm-disabled, branch-disabled, and branch-read-only Loyalty:
  checkout still records one sale, no new earn is created, and the prior 600
  balance remains persistent but is exposed only while effective policy permits
  customer Loyalty reads. Farah, assigned only to Orchard, cannot complete the
  Tampines comparison appointment.
- Two-staff calendar authoring: click Chen Wei's free 10:15 Day-view slot and
  save a Spa Ritual 60 appointment, then click Aisha Rahman's independently
  eligible column. Both staff/date/time values must be prefilled from the
  selected calendar cell, conflicts and Supplier training must stay
  non-selectable, and the saved appointments must survive refresh.
- Team and access setup: Olivia can add roster-only therapist **Nora Lee** with
  no login, or add **Aisha Rahman** with an email invitation and explicit
  Appointments `rw`, Customers `r`, Loyalty `r`, and Finance `off`. The same
  Team & permissions surface distinguishes employment/roster records from app
  access, exposes invite state, and reflects permission changes after Aisha
  refreshes. Maya may view the team but cannot grant access; Farah cannot open
  the owner-only writer.
- Profitability setup: Glow serum sells for SGD 68 with SGD 24 product cost.
  The owner must see SGD 44 gross profit and about 64.7% gross margin before
  choosing a reward. A reward proposal must state its cost assumption and show
  contribution after reward; it is never auto-published.
- Feedback: `CUS-MEI` submits one four-star internal rating and one separate
  five-star fixture. The company has a syntactically valid, synthetic Google
  Business review URL configured; both persisted ratings offer the same
  optional external link so the product does not selectively solicit positive
  reviews. Five-star copy may be warmer. A comparison tenant cannot read either
  record.
- Unified rewards overview: publish classic loyalty at 10 points per SGD with
  1,000 points redeeming SGD 10, plus an active **Birthday Glow** benefit. In a
  catalogue-model run, add two active rewards with the same customer-facing
  name but different UUIDs, costs and fulfilment so clicking either card proves
  stable-ID editor routing rather than name matching. A read-only manager sees
  the same published overview with no edit controls; a draft change must not
  appear to customers until explicit publication and owner/customer refresh.
- Reward source and starter tiers: an editable reward can remain custom or
  start from **Glow serum (retail)** / **Spa ritual 60**. Selection fills an
  editable customer reward name, description, selling price and company cost
  without publishing. With no tiers in the current draft, one owner action
  creates unpublished **Gold**, **Platinum** and **Diamond** tiers exactly once;
  thresholds and multiple benefit lines remain editable before publish.
- Launch-freeze reward image: one existing reward has a synthetic published
  image reference. The Grow editor must not expose a storage path/URL field or
  internal storage-contract wording; editing that reward preserves the exact
  reference, and the already-published image remains visible customer-side.
- Launch-freeze expenses: add one SGD 3.33 Orchard expense on 1 October 2031
  with a null category. P&L must succeed, include SGD 3.33 in totals/monthly
  reconciliation and group it as **Uncategorised** without mutating the row.
- Launch-freeze staff commission: retain one existing flat-commission sale and
  one percentage sale. The V145 projection preserves the established ten view
  columns and flat-over-percentage arithmetic, then appends the immutable
  revenue-classification flag without renaming or dropping `flat_cents`.
- Launch-freeze credit authority: Aisha has SGD 5.00 current credit and Devi,
  whose only visit is Tampines, has SGD 9.00. Olivia can see the exact SGD 14.00
  business liability when all-business source authority is complete. Orchard-
  only Farah/report reader receives an unavailable flag and null, never SGD 0
  or Devi's balance, on Dashboard and Reports.
- Launch-freeze Studio provenance: legacy incomplete rules are migration-paused
  even when no owner exists. Both pause and audit use the documented nil-UUID
  system sentinel, rendered as **Peekaa launch safety**; a real owner-initiated
  emergency pause continues to show that owner's actor.
- Simplified automatic setup: Olivia opens Grow with Loyalty `rw`, the same
  published Signature rewards and Birthday Glow, and no draft. The complete
  overview is visible before secondary controls. **Create recommended rewards
  draft** opens one compact review sheet that truthfully lists repeat visits,
  Facial, one earning rule plus one return reward, catalogue-price use, the
  missing fulfilment-cost assumption, excluded programme families and the
  unpublished boundary. Opening/cancelling writes nothing; the second tap
  creates one editable recommendation draft under a stable request key, and an
  induced lost response reuses that key. The success handoff summarizes model,
  threshold and reference price before **Review draft** opens the exact editor.
  With draft version 2 already present, **Continue rewards setup** opens it in
  one tap and performs no recommendation write. Repeat with Maya's read-only
  role (no setup control), at 1440px, 375/390/412px portrait and 844×390
  landscape. No primary action begins outside the viewport. Only after Olivia
  explicitly publishes may Chen/Farah fulfil it and `CUS-MEI` see it.
- V141 dashboard/customer usability: use Orchard plus the all-branches view
  with 22 visit entries and an explicit reversal-row comparison, SGD 1,737.30 revenue, three distinct identified
  purchasing customers, four customers joined in range, 75,831 points issued
  and zero current credit liability. Weekday visits are Mon 1, Tue 3, Wed 9,
  Thu 2, Fri 1, Sat 1, Sun 5 so quiet/medium/busiest colours are observable.
  Existing historical gender values include female, male and unknown; the UI
  does not add a gender-entry control. Sale items include Facial services,
  Glow serum retail goods, one Other/custom line, and a signed discount line
  that must be excluded from the gross positive item-mix chart. `CUS-MEI` has 300 points,
  Free tofu ready and one 300-point batch expiring 28 September 2026. Give
  `CUS-MEI`, both duplicate Lees, `CUS-ARUN` and `CUS-NEW` distinct synthetic
  joined dates. Run owner, manager and front desk at 1440px, 1180px iPad-class
  and 390px; include report, inactivity, item-detail, join-date and expiry
  error/retry states plus no-expiry/no-programme comparisons.
- Same-device QR and owner preview: Olivia, Farah and `CUS-MEI` each use a
  separate persistent browser profile. A customer join QR uses the current
  canonical/same-origin handoff without losing an existing session. Reload,
  tab reopen and PWA relaunch preserve the persona until explicit local
  sign-out. **Preview customer view** opens a clearly labelled, non-mutating
  preview from Olivia's owner session and never asks her to authenticate as a
  customer or exposes customer writers/personal balances.
- Promotions discovery: the Grow/settings hub provides one clear route to the
  existing company promotion editor. Olivia sees draft, published, unavailable
  and retry states; the customer projection still shows no more than the two
  current image-backed offers governed by v104.
- Public-route performance: compare bare and canonical root, customer join,
  public booking and business workspace at cold/warm cache. Each route leaves
  its skeleton for a truthful ready/empty/error state, preserves hash/query,
  and unrelated heavy dependencies do not block the initial route.

Promotion cases:

- owner draft for **National Day Glow**;
- exact offer facts: **30% off Spa Ritual 60**, celebrating National Day,
  valid through **30 August 2026**;
- CTA: **Book now** when customer booking is enabled, otherwise **View offer**;
- a real 16:9 JPEG/WebP with descriptive alt text;
- two simultaneous active offers for the normal customer projection;
- a third active offer to prove the server returns no more than two;
- one future, one expired, and one inactive offer, plus a non-null Tampines
  branch author/read attempt that must be rejected because v104 promotions are
  company-wide;
- ten active offers followed by an eleventh publish attempt for quota proof;
- wording-assistant inputs containing a percentage, date, and named service to
  prove those facts remain exact after polishing.

## `CAFE-HARBOUR` — Harbour Kopi

Sector: F&B / Café

Branches: Tanjong Pagar, Toa Payoh

Catalogue:

- Kopi — SGD 2.20
- Iced kopi — SGD 2.80
- Kaya toast set — SGD 6.50

Programme:

- stamp or points configuration using café-specific recommendations;
- an ordered stamp path: stamp 5 unlocks one Kopi; stamp 10 unlocks one Kaya
  toast set, with the second threshold displayed as the next five stamps after
  the first unlock;
- birthday benefit disabled;
- gift-card issuance enabled in one run;
- a seasonal reward published by platform campaign controls.

This fixture verifies that café benchmarks appear only for café firms.

## `FIT-NORTHSTAR` — Northstar Fitness

Sector: Fitness

Catalogue:

- Drop-in class — SGD 28
- 10-class pack — SGD 240
- Personal training 60 min — SGD 95

Use it for bookings, memberships, package expiry, class capacity, staff
assignment, and mobile booking acceptance.

## Customer category projection

Use `CUS-MEI` with existing QR-created links to `SPA-GLOW`,
`CAFE-HARBOUR`, and `FIT-NORTHSTAR`. The customer selector groups them under
Personal care, Food & drink, and Fitness while preserving the existing
programme links. Add one governed but unmapped synthetic sector to verify an
Other fallback. The fixture must not add business search or create any new
relationship.

## Customers

| ID | Identity | Purpose |
| --- | --- | --- |
| `CUS-MEI` | Mei Lin, synthetic SG mobile ending 4567 | Linked to several firms; has 5x Spa 60 with 4/5 left, points, and booking history. |
| `CUS-LEE-A` | Lee Wei, synthetic mobile ending 1001 | Duplicate-name search case. |
| `CUS-LEE-B` | Lee Wei, synthetic mobile ending 2002 | Duplicate-name search case. |
| `CUS-ARUN` | Arun Kumar, synthetic mobile ending 8877 | Owns a valid $50 legacy gift while new issuance is disabled. |
| `CUS-NEW` | New synthetic identity | No programmes before QR join. |

Customer inactivity cases as of 1 August 2026 Singapore time:

- `CUS-MEI`: latest valid visit 20 July 2026 (active; excluded from 30/60/90).
- `CUS-LEE-A`: latest valid visit 15 June 2026 (shown at 30 days only).
- `CUS-LEE-B`: latest valid visit 15 May 2026 (shown at 30 and 60 days).
- `CUS-ARUN`: latest valid visit 15 March 2026 (shown at 30, 60, and 90 days).
- `CUS-NEW`: no valid visit yet (shown in every inactivity filter as **Never visited**).

Appointment WhatsApp acceptance uses `CUS-MEI`'s synthetic Singapore mobile
ending 4567. The invalid-phone comparison customer has no mobile number; the UI
must not expose a dead WhatsApp action.

All automated credentials must come from a non-committed test-secret mechanism.

## Platform CRM and billing

| ID | Scenario |
| --- | --- |
| `PLAT-PENDING` | New spa firm awaiting Super Admin approval, assigned to Consultant Sarah. |
| `PLAT-WON` | Active café firm, annual subscription paid, next payment present. |
| `PLAT-OVERDUE-01` | Quarterly firm on day 1 overdue. |
| `PLAT-OVERDUE-14` | Half-yearly firm on day 14 overdue; owner access pause expected. |
| `PLAT-REFUND` | Annual invoice refunded after payment; GST and refund excluded from commission. |
| `PLAT-STAFF-LEFT` | Consultant departed before eligibility anniversary; commission returns to company. |

### `PLAT-PROSPECT-GLOW` — assisted-sales prospect persistence

- Prospect: Glow Advisory Pte. Ltd., synthetic UEN `202688888G`.
- Primary contact: Priya Nair with synthetic `@peekaa.invalid` email and a
  synthetic Singapore mobile ending 7788.
- Assigned consultant: Sarah; starting stage **New Lead**; tags
  `spa, warm-referral` normalized once each.
- Submit once, simulate a lost response after persistence, and retry with the
  same request identity. The board and database must still contain one prospect
  and one creation audit. Reusing the key with another company/UEN must fail
  without mutation.
- The operator may choose **Kanban** or **List** without changing the filtered
  records. The selected view survives refresh/back navigation. An unassigned
  Sales user cannot read or change the row; Sarah can read the assigned row but
  receives only her configured onboarding actions.

### `PLAT-FINANCE-AUG26` — Peekaa platform P&L, invoice and receipt

- Reporting period: 1–31 August 2026, Singapore time, SGD.
- Radiant Skin Studio pays one annual SGD 1,188.00 invoice with SGD 0.00 GST;
  Harbour Kopi has one pending monthly SGD 149.00 invoice excluded from cash.
- Northstar Fitness has one paid SGD 169.00 invoice followed by a provider-
  confirmed SGD 20.00 partial refund; a duplicate event has zero second effect.
- Platform expenses: SGD 280.00 software, SGD 120.00 marketing and one reversed
  SGD 45.00 duplicate software expense. The reversal keeps immutable source and
  actor evidence but contributes SGD 0.00 to the active expense total.
- The P&L must reconcile paid cash SGD 1,357.00 less refunds SGD 20.00 less
  active expenses SGD 400.00 to net cash SGD 937.00. Pending SGD 149.00 is
  labelled outstanding and excluded from cash and net cash.
- Paid rows expose exact provider invoice/document actions; pending rows never
  display a receipt. Unsafe or missing provider document URLs fail closed.

### `PLAT-BOOKS-FY26` — Peekaa automated books and controlled documents

- Entity: synthetic Peekaa Singapore private company, SGD functional currency,
  31 December FYE, explicitly **not GST-configured** until registration evidence
  is supplied. No tax invoice or InvoiceNow transmission may be claimed while
  that configuration is absent.
- The `PLAT-FINANCE-AUG26` invoices, payment, refund and active SGD 400.00
  expenses post once into balanced journals. Credit/debit/write-off accounting
  adjustments remain non-cash while their accrual accounts still reconcile.
- One synthetic SGD 250.00 non-subscription invoice to Meridian Wellness Pte.
  Ltd. is issued, partially paid SGD 100.00, then corrected by an immutable SGD
  50.00 credit note. The remaining receivable is SGD 100.00. Each issued
  document has a unique sequential number and exact journal link.
- Repeating an operation with the same identity returns the original document
  and journal. Reusing that identity with changed values fails without mutation.
  Corrections create linked reversal/replacement records; posted rows are not
  updated or deleted.
- A locked August period rejects new/backdated posting. Super Admin may read;
  delegated Admin, Sales, anonymous and tenant users are denied.

### `SPA-GLOW-BILLING` — launch pricing and capacity

- Monthly, 1,000 profiles: SGD 149.00 per month.
- Monthly, 3,000 profiles: SGD 169.00 per month (base plus two SGD 10 blocks).
- Annual, 1,000 profiles: SGD 1,188.00 paid up front (SGD 99/month equivalent).
- Annual, 3,000 profiles: SGD 1,428.00 paid up front (base plus two SGD 120 blocks).
- Annual is selected on first render. SGD 168/month is comparison copy only and
  is absent from all Stripe line-item amounts.
- Glow Atelier has 850 profiles for the first checkout, then 1,150 profiles to
  prove the customer count is authoritative. Use a 1,000-capacity subscription
  to test an immediate increase to 3,000 and confirm V124 renders no
  self-service decrease control.
- First successful paid invoice at `2026-08-01T04:15:00Z` produces one request
  deadline at `2026-08-31T04:15:00Z`. Cadence/capacity changes, cancellation and
  reactivation leave both timestamps unchanged. A paid invoice for a different
  legacy provider subscription is excluded; an earlier invoice for the same
  V124 subscription is backfilled and moves the deadline backward only.
- A newer complete Stripe snapshot that omits the capacity add-on deletes the
  stale local item and projects 1,000 capacity. A pending prorated update stays
  uncertain, and the same browser selection reuses its request key and command
  ID after a lost response. Once its webhook projects 3,000 capacity, the exact
  uncertain command remains recoverable even though requested and current
  capacity are equal. A later annual catalogue rollover uses different fixture
  price IDs but cannot change the original command snapshot. Terminal failed or
  canceled outcomes render explicit failure copy.
- Staff fixtures remain Olivia, Maya, Farah, Chen and Aisha. Adding or removing
  any of them changes permissions/scheduling but never the subscription total.
- Nestly operator GST registration is `false`; every V125 subscription invoice
  has SGD 0.00 tax and total equals subtotal. The fixture Stripe Prices use
  explicit `exclusive` tax behavior and Checkout automatic tax is disabled.
  An inclusive/unspecified Price, automatic-tax request, or non-zero provider
  tax total is rejected/fail-closed. Incorporation alone is not
  GST-registration proof.
- Overdue boundary: an invoice due `2026-08-01T00:00:00Z` leaves owner access
  open through `2026-08-14T23:59:59Z` (day 13) and pauses it from
  `2026-08-15T00:00:00Z` (day 14). `CUS-MEI` retains the same points, packages,
  history and customer access throughout. A causally newer paid event restores
  owner access and advances `next_payment_at`; duplicate/stale events do not.

### `SPA-GLOW-BILLING-NEW` — self-service owner signup

- Synthetic owner: Sofia Ng with a newly confirmed synthetic business email
  and no existing staff or customer persona.
- Business: Radiant Skin Studio, facial sector, synthetic UEN `202699999N`,
  workspace address `radiant-skin-studio`.
- Annual/1,000 is the first render and totals SGD 1,188.00 with GST not charged.
  Monthly/3,000 totals SGD 169.00. Neither selection contains staff quantity.
- Starting setup creates exactly one payment-pending workspace, owner staff row,
  default branch, published facial sector assignment, draft loyalty preset and
  V124 checkout command under stable replay keys.
- Stripe Checkout creation alone, cancellation, expiration or an unpaid
  subscription never opens the workspace. Only the matching normalized paid
  invoice after the V124 subscription projection creates the immutable 30-day
  request window and opens this exact workspace once.
- Re-run with an unconfirmed email, another user's business ID, a reused key
  with changed business/plan data, duplicate slug, inactive Stripe catalogue,
  forged amount, and a paid invoice for another subscription.
- V144 prospective-policy run: Sofia accepts the 2026-08-03 Terms using the
  single account-creation checkbox, optionally opens each legal link and
  returns to signup, then buys annual/1,000. The matching paid invoice activates
  once but creates no money-back window. A comparison business that earned a
  V124 window under earlier Terms keeps the exact immutable deadline. Empty or
  half-published Stripe catalogue rows show an actionable unavailable state and
  create neither a workspace nor a charge.

## `NESTLY-MOBILE-RELEASE-01` — store publication candidate

- Canonical source: exact V129/V131 `app/` bundle under application identifier
  `asia.nestly.app`; website origin `https://www.nestly.asia`; packaged origins
  `capacitor://localhost` and `https://localhost`.
- People: existing `SPA-GLOW` owner Sofia Ng, front desk Maya Lim, dual-role
  operator, and newly created synthetic customer `CUS-NEW`. No real customer
  identity, store credential, signing key or OTP is stored in evidence.
- Website path: a new owner may choose the reviewed annual/monthly V124 plan and
  continue to Stripe only on the public website.
- Packaged path: customer account creation and existing customer/owner/staff
  sign-in remain available; all paid subscription purchase/change/portal actions
  are absent with no external purchase link.
- Deletion path: the authenticated identity confirms **Delete account**, one
  pending request persists, exact replay returns the same request, another user
  and anonymous caller receive no request data, and no operational/financial
  record is deleted by the request writer.
- Device states: iPhone-class 390px and Android-class 412px portrait, one
  landscape pass, camera denied/allowed, offline cold start, reconnect,
  background/resume, expired session and universal/app-link launch.
- Distribution states: missing then valid Apple Team ID, missing then valid Play
  signing SHA-256, association 404/redirect/wrong type/valid 200, unsigned then
  signed archive/bundle, and store privacy/review metadata absent then complete.

## `PEEKAA-MOBILE-RELEASE-01` — V134 rebrand candidate

- Canonical source is the exact V134 `app/` bundle. Product display name is
  **Peekaa**, canonical website is `https://www.peekaa.asia`, and monitored
  contact is `admin.peekaa@gmail.com`. NESTLY TECHNOLOGIES PTE. LTD. (UEN
  202634502E) remains the legal operator.
- Master artwork is the owner-supplied opaque 1254×1254 RGB PNG. Derivatives
  cover browser favicon, Apple touch icon, PWA 192/512 maskable-safe icons, iOS
  opaque 1024px store icon and Android launcher foreground/background assets.
- Run signed-out, customer, owner/staff and platform entrypoints at desktop,
  390px and 412px. Test fresh install, cached V133 update, offline shell,
  notification icon context, splash, camera prompt and share/auth/join URLs.
- Existing `nestly.asia` routes redirect to `peekaa.asia` without losing query,
  fragment or deep-link intent. No current app/store/public copy presents Nestly,
  but historical evidence, migration names and legal entity records remain
  untouched.
- Stripe comparison uses the existing `SPA-GLOW-BILLING-NEW` arithmetic and a
  synthetic provider customer. The browser may pause for the owner to complete
  Stripe login, OTP, identity, representative, bank and final contractual
  confirmation. Credentials and identity evidence are never stored in git.

## `CAFE-HARBOUR-PAYMENTS` — connected F&B merchant POS

- Legal merchant Harbour Kopi has Tanjong Pagar and Toa Payoh branches. Both
  settle to the same synthetic connected account; a second merchant can never
  read or charge it.
- Tanjong Pagar catalogue includes **Harbour Lunch Set — SGD 10.00**. Staff
  Farah records it for `CUS-MEI`; the evaluated total is exactly 1,000 cents.
- Owner onboarding states are Not set up, More information needed, Ready and
  Restricted. Stripe-hosted links are single-use; no representative, bank, OTP,
  secret or identity-document value is stored in the fixture.
- A Ready attempt returns a realistic raw PayNow payload rendered locally and
  reserves the same immutable exact-price evaluation for 61 minutes, covering
  the provider's one-hour QR lifetime without a CSP-dependent remote image or a
  second checkout that another staff tab could consume.
  Signed `payment_intent.succeeded` from Harbour's connected account and exact
  SGD 10.00 finalises one sale, one payment, normal stock/points effects and one
  printable receipt. Wrong merchant, SGD 10.01, non-SGD, expired, failed,
  duplicate and out-of-order events finalise nothing.
- Automatic-refund comparisons exercise `pending`, signed `refund.updated`
  success, signed `refund.failed`, duplicate and out-of-order refund events,
  including a delayed `refunds.create` response that must not downgrade a
  signed failure.

## `SPA-GLOW-PAYMENTS` — second connected merchant isolation comparison

- Glow Atelier uses a different synthetic connected account and payout bank.
  Orchard and Tampines share it because they are branches of the same legal
  merchant.
- The checkout comparison is **Spa Ritual 60 — SGD 88.00**. A Harbour event or
  account identifier cannot create, inspect or complete this payment attempt.
- Owner, manager, front desk, read-only staff and outsider states prove that
  only the owner controls onboarding while permitted till staff may create and
  monitor an exact payment at an assigned Ready branch.

## Required state variations

Every relevant journey chooses from this list and records which variants were
run:

- zero, one, and many records;
- enabled, disabled, and enabled-but-unconfigured module;
- owner, manager, front desk, customer, dual-role, Super Admin, Admin, assigned
  Sales/Consultant, and unassigned Sales/Consultant;
- all branches, one branch, and wrong branch;
- happy path, validation failure, permission denial, server failure, timeout
  after write, retry, double tap, refresh, back/forward, logout/login, and
  reconnect;
- desktop, 390px-class iPhone viewport, and 412px-class Android viewport.
