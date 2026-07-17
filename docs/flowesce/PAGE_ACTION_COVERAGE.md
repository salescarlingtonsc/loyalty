# PAGE_ACTION_COVERAGE

Pass 1 — one row per discovered page/route. Read-only pass; **DISCOVERED is the expected,
correct status for most rows** — a page is not FULLY REVIEWED just because its landing view
opened. Where a page's behaviour was already exercised end-to-end in
`docs/benchmark/LIVE_DATA_WALKTHROUGH.md` (pass 4), that is cited explicitly and the status
reflects that prior work rather than re-claiming it as new.

Evidence tags used inline: **A** confirmed accessible behaviour (seen/done), **B** observed but
not fully tested, **C** inferred (reasoning, not observed — always labelled), **D**
hidden/inaccessible, **E** blocked (permission/data/tier/destructive-risk).

Audit status vocabulary used exactly as specified: NOT STARTED / DISCOVERED / PARTIALLY REVIEWED /
FULLY REVIEWED / BLOCKED / NOT ACCESSIBLE.

---

### FL-DASH-01 — Dashboard
- Parent module: — (top-level) · Route: `/dashboard` · Entry: sidebar link, logo link
- Accessible role: Owner (only role tested) · Purpose: daily command centre
- Tabs: none · Tables: none · Cards: greeting banner, trial-countdown banner, Today's appointments,
  Revenue·30 days, Low-stock alerts (partially scrolled off in this pass)
- Fields: none (read-only) · Filters: none · Buttons: "Add payment," "Dismiss until tomorrow"
- Dropdown actions: none observed · Record-detail actions: none · Create/Edit/Delete: none
- Status transitions: none · Imports/Exports/Print: none · Empty-state: N/A (tenant has data) ·
  Loading-state: not observed
- Audit status: **DISCOVERED** (A: banner numbers, KPI cards seen live and match known test data —
  $50 booked/revenue this week, 1 appointment today — consistent with LIVE_DATA_WALKTHROUGH.md)
- Outstanding questions: Low-stock alerts card content not scrolled into view this pass.

### FL-CAL-01 — Calendar
- Parent: — · Route: `/calendar` · Entry: sidebar
- Purpose: day/week/month appointment grid
- Tabs: day/week/month view toggle, status/staff colour toggle · Tables: week grid (rowgroup of
  hour rows, 7 day columns) · Cards: none · Fields: none
- Filters: "Filter by staff" (All staff) · Buttons: Previous/Next/Today, "New client," "Add"
- Record-detail actions: clicking an appointment block (seen: "Test Customer QA · Test Facial,"
  status "Completed") — not clicked into this pass
- Create actions: "Add" (new appointment on grid), "New client" · Edit/Delete: not tested ·
  Status transitions: colour legend shown (Booked/Confirmed/Arrived/Completed/Cancelled/No-show)
  but not exercised here (already exercised in LIVE_DATA_WALKTHROUGH.md steps 7a–7c)
- Imports/Exports/Print: none on this page · Empty-state: N/A · Loading-state: not observed
- Audit status: **PARTIALLY REVIEWED** (A: grid renders real data; B: day/week/month toggle and
  staff filter not clicked; status-transition mechanics confirmed via Appointments record in
  LIVE_DATA_WALKTHROUGH.md, not re-driven from this specific grid view)
- Outstanding questions: does drag-and-drop rescheduling work from this grid? (Prior pass flagged
  drag-drop as "their bug" — not re-tested.)

### FL-APPT-01 — Appointments (list)
- Parent: — · Route: `/appointments` · Entry: sidebar
- Purpose: list view of all appointments, alternate to Calendar
- Tabs: none · Tables: appointment rows (date/time/status/client/service/duration/staff/branch/
  amount/payment-status) · Fields: search box
- Filters: status, staff, branch, date range (all "All ___" defaults) · Buttons: "Print schedule"
  (`/print/schedule`), "Import CSV" (`/import/appointments`), "Export CSV"
  (`/api/export/appointments`), "New appointment," "View details"
- Record-detail actions: "View details" per row (not opened this pass; full lifecycle of this
  exact appointment already covered in LIVE_DATA_WALKTHROUGH.md steps 7a–7c)
- Create: "New appointment" modal (already live-tested in LIVE_DATA_WALKTHROUGH.md step 7) ·
  Edit/Delete: not tested this pass · Status transitions: already tested in prior pass (Booked →
  Confirmed → Arrived → Completed → Checkout/paid)
- Imports: CSV (button present, not exercised — would create records, out of Pass-1 scope) ·
  Exports: CSV (button present, not clicked to avoid any download/side effect ambiguity) · Print:
  "Print schedule" link present, not opened
- Empty-state: not observed (tenant has 1 appointment) · Loading-state: not observed
- Audit status: **PARTIALLY REVIEWED** (A: list render, filters, buttons all confirmed present and
  correctly labelled; status-machine behaviour is FULLY REVIEWED via the cited prior pass)
- Outstanding questions: none major.

### FL-REQ-01 — Requests
- Parent: — · Route: `/requests` · Entry: sidebar
- Purpose: approve/deny client-initiated cancel/reschedule requests
- Tabs: none · Sections: Cancellation requests, Reschedule requests, Recent decisions (all empty
  this pass — no client-side requests exist in the tenant)
- Fields: none · Filters: none · Buttons: "Auto-approve" toggle (switch + checkbox, both present)
- Record-detail/Create/Edit/Delete: N/A, nothing to act on · Status transitions: N/A this pass
- Empty-state: **A**, confirmed: "No pending cancel requests." / "No pending reschedule requests."
  / "No decisions in the recent window." · Loading-state: not observed
- Audit status: **DISCOVERED** (page mechanics were already confirmed live and working in a prior
  pass per PAGE_INVENTORY.md's note that this module "closed in v8" on the Frenly side after
  comparison; the underlying Flowesce approval flow itself has never actually been exercised
  end-to-end in any pass because the tenant has no pending requests to approve/deny)
- Outstanding questions: what does the approval modal look like, and does declining differ in UI
  from approving? Genuinely unknown (D/E — no test data available without a client-side booking
  portal action, which is out of admin-only reach).

### FL-WAIT-01 — Waitlist
- Parent: — · Route: `/waitlist` · Entry: sidebar, top-bar shortcut (DOM-confirmed, not re-clicked)
- Purpose: walk-in queue + online waitlist
- Tabs: none · Sections: Walk-in queue, Online queue (both empty) · Buttons: "Add walk-in"
- Empty-state: **A**, confirmed: "No walk-ins right now. Tap 'Add walk-in' when someone shows up."
  / "Nobody on the online waitlist. When customers sign up from the booking page they'll appear
  here."
- Create: "Add walk-in" not clicked (would create a record) · Edit/Delete/Status: not tested
- Audit status: **DISCOVERED**
- Outstanding questions: online-waitlist auto-email-on-matching-slot behaviour (noted in prior
  pass) not re-verified.

### FL-CLI-01 — Clients (list)
- Parent: — · Route: `/clients` · Entry: sidebar
- Purpose: client directory
- Tables: 1 row (Test Customer QA, qa-test@example.invalid, +65 9000 0001, 0 visits shown here vs.
  1 in LIVE_DATA_WALKTHROUGH — **note:** this pass's snapshot shows "visits" label present but the
  actual count for the field wasn't legible in the compact accessibility read; not a contradiction,
  just an unread value)
- Fields: search box · Filters: "Filters" button, sort combobox (Name A→Z) · Buttons: "Export CSV"
  (`/api/export/clients`), "Import CSV" (`/import/clients`), "Add client" (`/clients/new`)
- Record-detail: client card is a link into `/clients/:id` — this exact client's detail page was
  already fully explored in LIVE_DATA_WALKTHROUGH.md (Visits, Total spent, Last visit, Credit on
  file, prepaid-session credits all captured there)
- Create/Edit/Delete: Add-client form fields fully enumerated in LIVE_DATA_WALKTHROUGH.md step 6
- Audit status: **PARTIALLY REVIEWED** (list view DISCOVERED this pass; detail view and create
  form FULLY REVIEWED per the cited prior pass)
- Outstanding questions: Export CSV and the "Filters" button's contents not opened this pass.

### FL-INV-01 — Inventory (list)
- Parent: — · Route: `/inventory` · Entry: sidebar
- Purpose: stock items across branches
- Tables: 1 row (Test Cream, Both, Shared, piece, Jun 2027 expiry, $5.00 cost, $25.00 price, In
  stock) with columns Item/Kind/Branch/Stock/Committed/Threshold/Next expiry/Cost/Price/
  Supplier/Status
- Filters: category, branch, status (Active+archived), expiry, "Low stock only" toggle · Buttons:
  "Export CSV," "Import CSV," "Bulk adjust" (`/inventory/adjust`), "New item"
- Record-detail/Create: item form fully enumerated in LIVE_DATA_WALKTHROUGH.md step 4 (Kind
  3-way choice, FEFO batch tracking, "Sell online" storefront panel)
- Audit status: **PARTIALLY REVIEWED** (list view + filters DISCOVERED; item creation and
  Kind/FEFO mechanics FULLY REVIEWED per cited prior pass)
- Outstanding questions: "Bulk adjust" page never opened in any pass — genuinely unknown.

### FL-SVC-01 — Services (list)
- Route: `/services` · Purpose: service catalog
- Table: 1 row (Test Facial, 45 min, $50.00, Active) with an INVENTORY column showing "1" (from
  the service→product link)
- Buttons: Export/Import CSV, "New service"
- Audit status: **PARTIALLY REVIEWED** (list DISCOVERED; full field-by-field service-creation
  wizard, including the post-save-only Inventory/Variants tabs, FULLY REVIEWED in
  LIVE_DATA_WALKTHROUGH.md steps 3 & 5)
- Outstanding questions: "Variants" tab (adjacent to Inventory tab, mentioned but not itself
  opened in any pass) — genuinely unknown what it configures.

### FL-BUN-01 — Bundles
- Route: `/services/bundles` · Purpose: "Multi-service packages sold for one price."
- Buttons: "New bundle" (×2, header + empty-state) · Empty-state: **A**, "No bundles yet... Bundle
  multiple services together at a single price. Each item still books as its own appointment..."
- **Plan gate: none** — fully open on Solo trial, correcting the prior pass's inference.
- Audit status: **DISCOVERED**
- Outstanding questions: "New bundle" form never opened in any pass.

### FL-PKG-01 — Packages (credit packages)
- Route: `/services/credit-packages` · Purpose: "Prepaid credit bundles clients can buy and redeem
  against future bookings."
- Buttons: "New package" (×2) · Empty-state: **A**, "No packages yet... Sell prepaid sessions: a
  fixed-service package or a pooled package across multiple services."
- **Plan gate: none** — fully open on Solo trial.
- Audit status: **DISCOVERED**
- Outstanding questions: form never opened; this is the same accounting-shape module the Frenly
  side flagged as an open v10 question (`sell_package`/`use_package_session` visit-counting) — the
  Flowesce UI copy itself ("prepaid... redeem against future bookings") was captured but the
  underlying accounting behaviour (does purchase count as a "visit" here too?) was NOT live-tested
  in Flowesce in any pass. Genuinely open.

### FL-MEM-01 — Memberships
- Route: `/memberships` · **Plan gate: hard paywall.** Full lock screen: "Memberships (recurring
  plans with monthly service credits) is a Growth feature," "Upgrade to Growth," "See what's
  included."
- Audit status: **BLOCKED** (E — plan tier)
- Outstanding questions: none new; consistent with all prior passes.

### FL-LOY-01 — Loyalty
- Route: `/loyalty` · **Plan gate: hard paywall.** "Loyalty program (points or stamp cards that
  earn in-store credit) is a Growth feature."
- Audit status: **BLOCKED** (E — plan tier). Confirmed in pass 4 that populating the tenant with
  real data does not unlock it — purely tier-based, not data-completeness-based.
- Outstanding questions: none new.

### FL-RES-01 — Resources
- Route: `/resources` · Purpose: "Rooms, chairs, and equipment that services book. The slot finder
  treats them as a constraint..."
- Buttons: "New resource" (×2) · Empty-state: **A**, "No resources yet... Once a service links to
  a resource, the slot finder..."
- Audit status: **DISCOVERED**
- Outstanding questions: never populated/opened in any pass — the "Resources" tab seen empty on
  the Test Facial service form (step 3 of prior pass) is consistent with 0 resources existing.

### FL-TRX-01 — Transactions
- Route: `/transactions` · Purpose: "Every payment taken: walk-in sales, retail, packages, and
  money collected on appointments."
- Tabs: All/Sales/Appointments · Filters: date range (Jun 18–Jul 17, 2026), type, staff, method ·
  Cards: Net revenue $75.00, breakdown Sales $25.00 / Appointments $50.00
- Table: 3 rows visible in this pass matching LIVE_DATA_WALKTHROUGH.md exactly — gift card sold
  $25 cash, retail sale, appointment payment — each with a "Refund" row action
- Buttons: "Export CSV" (`/api/export/transactions?`) · Row action: "Refund" (present, **not
  clicked** — refunds are explicitly out of Pass-1 scope)
- Audit status: **PARTIALLY REVIEWED** (A: figures cross-checked and match pass-4's confirmed
  numbers exactly — $75 net, $25/$50 split; B: Refund flow visible but not opened)
- Outstanding questions: Refund flow/modal never opened in any pass — genuinely unknown what
  fields it asks for or whether partial refunds are supported.

### FL-GFC-01 — Gift cards
- Route: `/gift-cards` · Purpose: "Sell gift cards in person."
- Cards: Outstanding gift-card balances $25.00 (matches the one card sold in pass 4) · Buttons:
  "Sell gift card" (not re-clicked — would create a second card)
- Settings form on same page: Preset amounts (3 slots + "Add preset"), Default expiry (months),
  "Sell online" toggle (tied to Storefront), Terms text, "Save"
- Audit status: **PARTIALLY REVIEWED** (balance figure confirmed A; settings form fields
  enumerated but not saved/changed this pass — B)
- Outstanding questions: none major; sale flow itself FULLY REVIEWED in LIVE_DATA_WALKTHROUGH.md
  step 9a.

### FL-CSH-01 — Cash drawer
- Route: `/cash-drawer` · Purpose: expected-vs-actual cash per branch
- Cards: Expected in drawer $100.00, Opening float $0.00, Cash in +$100.00, Cash out −$0.00 (all
  match pass-4's cumulative cash total: $50 service + $25 retail + $25 gift card)
- Table: 1 row, "Open" session, Expected $100.00
- Buttons: "Close count," "New pay-in," "New pay-out" — **none clicked** (Close count would end the
  open drawer session, a state change judged too disruptive/irreversible-feeling for Pass 1;
  pay-in/pay-out would create ledger entries)
- Audit status: **PARTIALLY REVIEWED** (A: read-only figures confirmed and reconciled exactly
  against pass-4 math; B: the three action buttons never exercised in any pass)
- Outstanding questions: what does "Close count" ask for (actual counted cash vs. expected,
  presumably), and what happens to the difference? Genuinely unknown.

### FL-EXP-01 — Expenses
- Route: `/expenses` · Tabs: One-time (`/expenses`) / Recurring (`/expenses/recurring`) · Filters:
  "All expenses" combobox, "Filters" button · Buttons: Export CSV, "New expense," "Show voided"
- Empty-state: **A**, "No expenses yet... Track what the business spends so reports show net
  profit, not just revenue. Multi-currency supported."
- Audit status: **DISCOVERED**
- Outstanding questions: Recurring tab never opened; "New expense" form never opened in any pass.

### FL-RPT-01 — Reports (main)
- Route: `/reports` · Date range: Jun 17–Jul 17, 2026 (default trailing 30 days)
- Cards: Revenue (paid) $75.00, Expenses $0.00, Net $75.00, Discounts given $0.00, Inventory cost
  used $10.00, Commissions earned $0.00, Cancellations 0/0 — all reconciled exactly against
  pass-4's final numbers
- Charts: Revenue by day, Top services · Tabs (11): By branch, By service, Commissions, Tips, Tax,
  Expenses, Unpaid balances, Cancellations, Inventory used, Credits, Bundles — **2 more tabs than
  the 9 recorded in the prior pass** (Credits and Bundles are new to this pass's read)
- "By branch" tab opened: Test Branch, 1 (row shows "$75.00" — appears to be completed-appointment
  revenue only, i.e. the $50 service sale, not the full $75 including the $25 retail Quick Sale;
  **this is worth a closer look in Pass 2**, flagged rather than asserted)
- Buttons: "P&L statement" link (`/reports/pl?...`), "Export CSV," "Email reports"
- Audit status: **PARTIALLY REVIEWED** (A: top-line KPI cards fully cross-checked; B: only 1 of 11
  sub-tabs opened this pass; P&L statement link and "Email reports" not opened)
- Outstanding questions: the By-branch $75.00-vs-$50.00 apparent inconsistency noted above needs
  Pass-2 clarification — is By-branch scoped to appointment revenue only, or is there a genuine
  discrepancy? Not resolved here.

### FL-PAY-01 — Payroll
- Route: `/reports/payroll` · **Correction: this is a real, working page — prior pass's 404 was a
  wrong-URL guess (`/payroll`), not a real 404.**
- Cards: Gross pay $0.00, Commission earned $0.00, Unpaid commission $0.00, Hours logged 0.00
- Tabs: Overview, Commission payouts, Hours · Table: Test Staff row (0 hours, $0 commission, $0
  tips, $0 gross)
- Buttons: "Generic CSV" and "Talenox CSV" export links (both with `from`/`to` query params) · Pay
  period picker (Jun 17–Jul 17, 2026)
- Audit status: **DISCOVERED** (first-ever look at this page across all 4 passes)
- Outstanding questions: why is commission $0 when Test Facial's completed+paid appointment should
  presumably generate a commission if Test Staff has a commission rate set — but Test Staff's
  commission fields were deliberately left blank in pass 4 (step 2: "Commission tab (left blank)"),
  so $0 is expected/consistent, not a bug. "Commission payouts" and "Hours" tabs not opened.

### FL-BRN-01 — Branches
- Route: `/branches` · 1 branch: Test Branch, "No address added," Active, "No phone," "No email,"
  hours "Sun 09:00–17:00 · +6 days," Staff/Today/This-month stat widget, "View & edit" link into
  `/branches/:id`
- Section: "Yearly holidays" — "Add holiday" button, empty: "No yearly holidays set." (new find —
  not previously recorded as a distinct section)
- Plan gate: "Upgrade to Growth to add more branches" (soft — 1-branch tenant fully functional)
- Audit status: **PARTIALLY REVIEWED** (list + Yearly-holidays DISCOVERED here; branch
  create/edit form fully enumerated in LIVE_DATA_WALKTHROUGH.md step 1)
- Outstanding questions: Yearly holidays "Add holiday" form never opened.

### FL-STF-01 — Staff
- Route: `/staff` · 1 staff: Test Staff, Active, Test Branch, Specialties: Test Facial, Today's
  schedule "1 appointment," "View schedule"/"Edit" links
- Buttons: "View timesheets" (`/staff/timesheets`), "Team off-days" (`/staff/off-days`), "Add
  staff" — **both timesheets and off-days are new finds, not in any prior pass**
- Audit status: **PARTIALLY REVIEWED** (list DISCOVERED + 2 new linked pages found; staff
  create form fully enumerated in LIVE_DATA_WALKTHROUGH.md step 2)
- Outstanding questions: Timesheets and Team off-days pages never opened — genuinely unknown
  content.

### FL-WEB-01 — Website
- Route: `/website` · **Correction: confirmed genuine screen-size gate, not a broken/stuck page.**
  Exact copy: "Open the website builder on a larger screen. The drag-and-drop website builder
  needs a desktop or laptop. Open this page on a bigger screen to design your site. Your published
  site still works on every device."
- Audit status: **BLOCKED** (E — this pass's tooling could not achieve a wide-enough effective
  viewport; not a Flowesce defect)
- Outstanding questions: full builder UI remains completely unseen across all 4 passes.

### FL-STO-01 — Storefront
- Route: `/storefront` · Purpose: "Sell retail products on your website... Fulfilling an order
  records a sale and deducts stock."
- Links: "Migrate from Shopify" (`/import/shopify`), "View store"
  (`https://carlington-smith-consultancy-pte-ltd.flowesce.com/shop`, not opened — customer-facing)
- Form: Shop settings — "Shop is open" toggle (off by default), "Offer pickup" + instructions,
  "Offer shipping," "Manual payment" (QR upload, bank transfer details, payment instructions),
  "Order reminders" toggle + threshold (default "2 days"/48h)
- Audit status: **PARTIALLY REVIEWED** (A: all fields enumerated; B: none saved/toggled)
- Outstanding questions: none major.

### FL-ORD-01 — Store orders
- Route: `/storefront/orders` · **Correction: real page, prior pass's `/store-orders` 404 was a
  wrong URL.**
- Sections: Pending (empty: "No pending orders."), Confirmed (empty: "No confirmed orders waiting
  to fulfil.") · Header copy: "0 open · reserve-only orders from your website shop. Fulfilling an
  order records a retail sale and deducts stock."
- Audit status: **DISCOVERED**
- Outstanding questions: no orders exist to open a record-detail view; fulfilment flow completely
  unseen.

### FL-MKT-01 — Marketing (hub)
- Route: `/marketing` · Purpose: "Broadcasts, birthdays, and client engagement."
- Cards: Reachable clients 1 (100%), Total clients 1, Opted out 0 — matches pass-4 exactly
- Buttons/links: "Edit brand," "Send log" (`/marketing/email-log`), "Birthday emails"
  (`/marketing/birthday`), "New campaign" (`/marketing/new`) — all 3 links new finds this pass
- Table: Campaigns (empty: "No campaigns yet. Compose your first one above.")
- Audit status: **PARTIALLY REVIEWED** (A: KPI cards cross-checked; B: none of the 4 linked
  actions opened)
- Outstanding questions: Send log, Birthday emails, and New campaign pages never opened.

### FL-RVW-01 — Review feedback
- Route: `/marketing/feedback` · **Correction: real page, prior pass's `/reviews` and
  `/review-feedback` 404s were wrong URLs (correct path nests under Marketing).**
- Purpose: "Responses to your post-visit review ask. Happy clients are sent to your public
  review; unhappy ones..." (truncated in the read, full sentence not captured)
- Form: "Review destinations" — Label + Review URL fields (e.g. "Google" / `https://g.page/r/...`),
  "Add destination" button
- Empty-state: **A**, "No responses yet. Set your review link in Settings → Business, then add the
  variable to the post-visit... {review_link}"
- Audit status: **DISCOVERED**
- Outstanding questions: what happens on the "unhappy" branch (truncated copy) — is there an
  internal-only feedback capture before the public review ask? Not resolved this pass.

### FL-REF-01 — Referrals
- Route: `/marketing/referrals` · **Not previously live-tested in any pass** (prior passes only had
  the marketing-site mechanics description).
- Cards: Referrals count, Rewarded, Credit issued $0.00 · Empty-state: "No referrals yet. Once a
  new client books with a client's referral code, it shows up here."
- Form ("Program settings"): "Referral program is on" toggle, Referrer reward (USD), New client
  reward (USD), Minimum spend to earn (USD, "No minimum" default), Reward expires after (days,
  "Never" default)
- **Plan gate: none** — fully open and configurable on Solo trial.
- Audit status: **DISCOVERED**
- Outstanding questions: is the referral toggle currently on or off in this tenant? Not legible in
  the compact accessibility read (checkbox state not captured); needs a screenshot check in Pass 2.

### FL-JRN-01 — Journeys
- Route: `/marketing/journeys` · **Correction: real page, prior pass's top-level `/journeys` 404
  was a wrong URL.**
- Purpose: "Automated multi-step client flows that send themselves when a trigger fires."
- **Plan gate: soft** — "Journeys are part of the Growth plan... You can build one now. To set it
  live and start sending, upgrade to Growth." Builder itself ("New journey," "Create your first
  journey") is not locked.
- Empty-state: "No journeys yet."
- Audit status: **DISCOVERED**
- Outstanding questions: the actual journey-builder canvas (trigger/step editor) never opened in
  any pass.

### FL-PRM-01 — Promotions
- Route: `/promotions` · Purpose: "Time-windowed discounts for your public booking page."
- Button: "New promotion," "How promotions work" info toggle · Empty-state: "No promotions yet...
  Run a June discount, hand out a one-time SUMMER10 code, comp a service category."
- Scope note (quoted, short, factual): "v1 scope" — promotions apply to single-service public
  bookings only; multi-item bookings ignore the code box; once used once, a promotion can't be
  deleted (only paused, to preserve cap-count history)
- Status legend: Live / Scheduled / Expired / Paused
- Audit status: **DISCOVERED** (unchanged from prior pass — re-confirmed, not re-tested deeper)
- Outstanding questions: "New promotion" form never opened in any pass.

### FL-FRM-01 — Forms
- Route: `/forms` · 1 form: "test" (pre-existing, not created by us — same anomaly noted in
  LIVE_DATA_WALKTHROUGH.md), Fields "description?," Signature "Required," "Not attached," Status
  "Live"
- Tabs: All/Live/Paused · Buttons: "Add from template," "New form"
- Heads-up copy (quoted, short): forms are "informational, not a hard block" — an appointment
  books/completes normally even with unfilled required forms; missing forms just surface as a red
  badge on the appointment
- Audit status: **PARTIALLY REVIEWED** (A: list + status legend confirmed; B: the pre-existing
  "test" form's own edit page never opened in any pass — still an open mystery per pass 4's note)
- Outstanding questions: origin of the pre-existing "test" form remains unexplained.

### FL-SET-01 — Settings → Business
- Route: `/settings/business` (+ query-param sub-tabs `?section=booking-page` /
  `booking-rules` / `emails` / `finance`)
- Sub-tabs (5): General, Booking page, Booking rules, Emails, Finance
- General fields: Business name, Booking slug (public URL shown live:
  `flowesce.com/book/carlington-smith-consultancy-pte-ltd`), Contact email, "What you call your
  staff" (combobox, default "Stylist," explicit UI-copy example "Choose your Stylist")
- Booking-page fields (partial read): Tagline (placeholder "Cuts. Colour. Confidence."), About us
- Audit status: **PARTIALLY REVIEWED** (General tab fields fully enumerated; Booking page tab
  partially read/truncated; Booking rules/Emails/Finance sub-tabs not opened at all this pass)
- Outstanding questions: Booking rules, Emails, and Finance sub-tabs of this same page are
  completely unexplored.

### FL-SET-02 — Settings → Account
- Route: `/settings/account` · Audit status: **DISCOVERED** (heading only; fields not enumerated)
- Outstanding questions: full form contents unknown.

### FL-SET-03 — Settings → Billing
- Route: `/settings/billing` · Not re-opened this pass; fully enumerated in prior pass
  (`PAGE_INVENTORY.md`: trial banner, Solo vs Growth plan cards, Monthly/Annual toggle, Add payment
  method).
- Audit status: **PARTIALLY REVIEWED** (carried from prior pass, not re-verified this pass)
- Outstanding questions: none new.

### FL-SET-04 — Settings → Team
- Route: `/settings/team` · Headings confirmed: "Expertise levels," "Team invites are a Growth
  feature," "Team members (1)"
- Audit status: **DISCOVERED** (re-confirmed structure only; field-level detail from prior pass
  still stands: Senior/Junior expertise levels, role tiers Owner/Manager/Receptionist/
  Bookkeeper/Staff)
- Outstanding questions: none new.

### FL-SET-05 — Settings → Integrations
- Route: `/settings/integrations` · **First-ever look inside this tab (all prior passes only
  listed it unopened).**
- Sections seen: "Sending domain" (Resend-backed, "Not set up," default sender
  `noreply@mail.flowesce.com`, "Set up" button), "Custom booking domain" (Growth-feature badge,
  "Put your booking page on your own subdomain so clients book at book.yoursalon.com instead of
  flowesce.com/book/your-slug")
- Audit status: **DISCOVERED**
- Outstanding questions: page continues below the fold (Google Calendar sync, mentioned in
  billing-plan copy from a prior pass, was not confirmed to live on this exact tab this pass).

### FL-SET-06 — Settings → Text & WhatsApp
- Route: `/settings/messaging` · Audit status: **DISCOVERED** (heading only)
- Outstanding questions: full form contents unknown.

### FL-SET-07 — Settings → Policies
- Route: `/settings/policies` · **First-ever look inside this tab.**
- Sections: Booking policies, Preset, Cutoffs (cancel/reschedule), Late cancel fee, No-show fee,
  Card on file, Policy text, Payment instructions
- Audit status: **DISCOVERED**
- Outstanding questions: individual field values/defaults within each section not read.

### FL-SET-08 — Settings → Brand
- Route: `/settings/brand` · Heading: "Brand kit" · Audit status: **DISCOVERED** (heading only)
- Outstanding questions: full contents unknown (logo upload? colour palette? — not confirmed).

### FL-SET-09 — Settings → Payments
- Route: `/settings/payments` · Audit status: **DISCOVERED** (heading only)
- Outstanding questions: full contents unknown — this is presumably where a card processor/Stripe
  SG connection would live, directly relevant to the Frenly side's deferred Stripe SG decision, but
  nothing beyond the section heading was confirmed this pass.

### FL-SET-10 — Settings → Data & privacy
- Route: `/settings/data` · Audit status: **DISCOVERED** (heading only)
- Outstanding questions: full contents unknown — directly relevant to PDPA ⚖️ flagged in the
  Frenly CLAUDE.md; needs a real look in Pass 2.

### FL-SET-11 — Settings → Import
- Route: `/settings/import` · Headings: "Import data," "Import from a CSV"
- Audit status: **DISCOVERED**
- Outstanding questions: **open question, flagged explicitly** — is this a hub/superset of the
  per-module Import CSV links already seen on Clients/Inventory/Services/Appointments, or a
  distinct fifth import surface? Not resolved this pass; do not assume either answer.

### FL-ALLF-01 — All features
- Trigger: sidebar footer button (not a route — opens a modal)
- Purpose: **not a static directory** — a page-visibility manager: "Jump to any page, or hide the
  ones you do not use. Hidden pages stay here and are always one click away." Every page listed
  with an eye icon to hide/show it, grouped MAIN/CATALOG/FINANCE/WORKSPACE/ENGAGEMENT.
- Audit status: **DISCOVERED** (opened live, scrolled partially; not every page's eye-icon toggle
  individually tested — toggling one was avoided to not alter the tenant's own nav configuration)
- Outstanding questions: does hiding a page here actually remove it from the main sidebar, or just
  reorder it? Not tested (would be a state-changing action).

### FL-FDBK-01 — Feedback
- Trigger: sidebar footer button, next to All features
- Audit status: **NOT STARTED** — seen in the sidebar, never clicked/opened this pass.

### FL-NOTIF-01 — Notifications
- Trigger: bell icon, top bar, present on every page
- Content: **A**, opened live — heading "Notifications," mute toggle, "Mark all read" (disabled,
  correctly reflecting the empty state), empty-state icon + "You're all caught up. We'll ping you
  when something new lands.", "View all notifications" link
- Audit status: **PARTIALLY REVIEWED** (panel itself fully seen; "View all notifications" not
  clicked through, and since the tenant currently has zero notifications, populated-state
  behaviour is entirely unverified)

### FL-ACCT-01 — Account/profile menu
- Trigger: avatar "Z," top bar, present on every page
- Content: **A**, opened live — header "Zeph Lee / carlingtonsmith.biz@gmail.com / Owner," then
  Account, Preferences, Settings, Billing, Help, Sign out
- Audit status: **PARTIALLY REVIEWED** (menu itself fully seen; none of its 6 items clicked
  through — Account/Preferences/Help specifically have never been opened in any pass; Sign out
  correctly not tested per scope boundary)

### FL-THEME-01 — Theme toggle
- Trigger: moon/sun icon, top bar
- Content: **A**, confirmed live — one click flips the entire app dark↔light instantly (banner,
  cards, background all repainted correctly), icon itself swaps moon↔sun to reflect state
- Audit status: **FULLY REVIEWED** (this is genuinely a complete, simple toggle with no further
  surface to test)

### FL-QS-01 — Quick sale (global shortcut)
- Trigger: top-bar button, present on every list-page banner
- Audit status: **PARTIALLY REVIEWED** — full modal flow (client picker, Retail tab, item pick,
  payment method, charge) already FULLY REVIEWED live in `LIVE_DATA_WALKTHROUGH.md` step 8; this
  pass only re-confirmed the button's continued presence in the DOM (a click attempt this pass did
  not visibly open the modal, most likely because the underlying page had navigated between the
  read and the click — not re-attempted further given this flow's behaviour is already
  authoritatively documented).

### FL-NAPPT-01 — New appointment (global shortcut)
- Trigger: top-bar button + page-level button on Appointments/Calendar
- Audit status: **FULLY REVIEWED** via `LIVE_DATA_WALKTHROUGH.md` step 7 (full field list, staff
  auto-assignment, email-confirmation checkbox all previously captured); this pass only
  re-confirmed presence.

### FL-WLSHORT-01 — Waitlist (global shortcut)
- Trigger: top-bar button, distinct from the full Waitlist page
- Audit status: **DISCOVERED** (DOM-confirmed present; not clicked — unclear if it opens a modal
  or just navigates to `/waitlist`)

### FL-SEARCH-01 — Global search (⌘K)
- Trigger: top-bar "Search clients and appointments" button
- Audit status: **NOT STARTED** — confirmed present in DOM with heading "Search" and placeholder
  "Find a client or an appointment," but never opened/typed into in any of the 4 passes to date.
  Genuinely the least-covered top-bar capability.
