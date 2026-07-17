# FLOWESCE_MASTER_INVENTORY

Pass 1 — Discovery only (read-only; no records created, edited, or deleted in this pass).
Session: app.flowesce.com, authenticated as Owner "Zeph Lee" (carlingtonsmith.biz@gmail.com),
tenant "CARLINGTON SMITH CONSULTANCY PTE. LTD.", Solo trial (13 days left at time of this pass).

**Prior work incorporated, not redone:** `docs/benchmark/PAGE_INVENTORY.md` (passes 1–3) and
`docs/benchmark/LIVE_DATA_WALKTHROUGH.md` (pass 4, live test data + full lifecycle test — that
test data, e.g. Test Branch/Test Staff/Test Facial/Test Cream/Test Customer QA/gift card
`GIFT-ETEV-5WJB`, still exists in the tenant and was reused here to reach record-detail screens).

**Tooling caveat (read once, applies throughout both files):** this pass's browser session
rendered the app at an effective CSS viewport of 606×653px regardless of the underlying browser
window size (tried resizing to 1600×1000 — no effect on the app's internal breakpoint). Flowesce
is responsive and treats that width as "mobile," which has two real consequences, both noted
inline where relevant:
1. The left sidebar is a slide-over dialog opened via a hamburger icon rather than a fixed rail.
   This did not block discovery — the dialog exposes the identical route list.
2. Two things were confirmed to be **genuinely screen-size-gated by Flowesce itself, not broken**:
   the Website builder (explicit copy: "Open the website builder on a larger screen... needs a
   desktop or laptop") and, per the accessibility tree, the top-bar Quick Sale / New appointment /
   Waitlist / global-search shortcuts render off-canvas at this width (confirmed still present in
   the DOM with exact labels — this is a rendering limitation of this pass's tooling, not a gap in
   Flowesce). Quick Sale and New-appointment were both already live-tested end-to-end in
   `LIVE_DATA_WALKTHROUGH.md` (pass 4), so functional coverage of those two exists despite this
   session not being able to visually drive them again.

## Discovery methods actually performed

1. **Sidebar, expanded, full route list captured via accessibility-tree dump** (not screenshots
   alone) — every link's href recorded directly from the DOM, both grouped by section (Catalog /
   Finance / Workspace / Engagement) and flat. This is how three routes prior passes marked 404
   were found to be real (see Corrections below) — prior passes had guessed URLs by pattern
   instead of reading the actual `href` attributes.
2. **"All features" page** — opened live. It is not a static directory; it is a page-visibility
   manager ("Jump to any page, or hide the ones you do not use. Hidden pages stay here and are
   always one click away.") with a per-page eye-icon toggle, grouped by the same MAIN / CATALOG /
   FINANCE / WORKSPACE / ENGAGEMENT sections as the sidebar.
3. **Account/profile menu** — opened live: Zeph Lee / carlingtonsmith.biz@gmail.com / Owner, then
   Account, Preferences, Settings, Billing, Help, Sign out.
4. **Notification bell** — opened live: empty state "You're all caught up," mute toggle, "Mark all
   read" (disabled when empty), "View all notifications" link.
5. **Settings and every settings subsection** — 11 tabs confirmed via sidebar: Business, Account,
   Billing, Team, Integrations, Text & WhatsApp, Policies, Brand, Payments, Data & privacy, Import.
   The Business tab itself has 5 further sub-tabs via query param: General, Booking page, Booking
   rules, Emails, Finance.
6. **Routes discovered via links/buttons on list pages** — Export/Import CSV links, Print schedule,
   Bulk adjust, Migrate from Shopify, Email log, Birthday emails, New campaign, Team off-days, Staff
   timesheets — all captured as real `href`s while reading each list page, not guessed.
7. **Record-detail pages** reached via the pass-4 test data: one client, one staff member, one
   branch, one service, one inventory item, one completed+paid appointment, one gift card, one
   sale/transaction row — reused rather than creating new records (scope boundary: no new writes).
8. **Role/plan-gating** — every gated page was opened live and its exact gate text captured (see
   Plan-gating table below); distinguished hard paywall vs. soft "can configure, can't activate."

## Reconciliation against the mandated checklist

Every item on the owner's reconcile list was found and is real (not a 404, not a guess). This is a
correction versus `PAGE_INVENTORY.md`'s third pass, which had marked four of these as 404 because
it tried invented URLs (`/payroll`, `/store-orders`, `/reviews`, `/review-feedback`, `/journeys`)
instead of the real ones now confirmed from the sidebar's own `href` attributes:

| Reconcile item | Found? | Real route | Correction vs. prior pass |
|---|---|---|---|
| Dashboard | Yes | `/dashboard` | — |
| Calendar | Yes | `/calendar` | — |
| Appointments | Yes | `/appointments` | — |
| Requests | Yes | `/requests` | — |
| Waitlist | Yes | `/waitlist` | — |
| Clients | Yes | `/clients` | — |
| Inventory | Yes | `/inventory` | — |
| Services | Yes | `/services` | — |
| Bundles | Yes | `/services/bundles` | **Correction:** prior pass listed Bundles as Growth-gated/404-adjacent by inference from marketing copy; live check this pass shows it fully open on Solo trial ("New bundle", empty state, no paywall). |
| Packages | Yes | `/services/credit-packages` | **Correction:** same as Bundles — fully open on Solo, not gated. |
| Memberships | Yes | `/memberships` | Confirmed still hard Growth-gated (paywall screen), consistent with prior passes. |
| Loyalty | Yes | `/loyalty` | Confirmed still hard Growth-gated (paywall screen), consistent with prior passes. |
| Resources | Yes | `/resources` | — |
| Transactions | Yes | `/transactions` | — |
| Gift cards | Yes | `/gift-cards` | — |
| Cash drawer | Yes | `/cash-drawer` | — |
| Expenses | Yes | `/expenses` | — |
| Reports | Yes | `/reports` | — |
| Payroll | Yes | `/reports/payroll` | **Correction (major):** prior pass's URL `/payroll` 404'd; the real route is nested under Reports. Fully functional: Overview / Commission payouts / Hours tabs, Generic CSV + Talenox CSV export, per-staff gross-pay table. NOT a 404, NOT gated. |
| Branches | Yes | `/branches` | — |
| Staff | Yes | `/staff` | — |
| Website | Yes | `/website` | **Correction:** prior pass called this "inconclusive / stuck loading." It is not broken — it is a genuine, explicitly-messaged screen-size gate ("Open the website builder on a larger screen... The drag-and-drop website builder needs a desktop or laptop. Your published site still works on every device."). Confirmed by exact on-screen copy, not inferred. |
| Storefront | Yes | `/storefront` | — |
| Store orders | Yes | `/storefront/orders` | **Correction (major):** prior pass's URL `/store-orders` 404'd; real route is nested under Storefront. Fully functional: Pending / Confirmed sections, explicit copy "Fulfilling an order records a retail sale and deducts stock." NOT a 404. |
| Marketing | Yes | `/marketing` | — |
| Review feedback | Yes | `/marketing/feedback` | **Correction (major):** prior pass tried `/reviews` and `/review-feedback` (both 404); real route is nested under Marketing. Fully functional: review-destination config (label + URL, e.g. Google), `{review_link}` template variable, response log. NOT a 404. |
| Referrals | Yes | `/marketing/referrals` | Not live-tested before (prior passes only had the marketing-site mechanics page). Confirmed live and fully open on Solo (not gated): referrer/new-client reward amounts, min spend, reward expiry, on/off toggle. |
| Journeys | Yes | `/marketing/journeys` | **Correction (major):** prior pass tried top-level `/journeys` (404); real route is nested under Marketing. Not a hard gate either — you **can build** a journey on Solo trial; the gate is only on going live ("Journeys are part of the Growth plan... You can build one now. To set it live and start sending, upgrade to Growth."). This is a materially different, softer gate than Loyalty/Memberships' outright paywall. |
| Promotions | Yes | `/promotions` | — |
| Forms | Yes | `/forms` | — |
| Settings | Yes | `/settings/business` (+10 more tabs) | — |
| All features | Yes | button, not a route | Turns out to be a page-visibility manager, not a static list — see Discovery method #2. |
| Feedback | Yes | button (opens a feedback form, not opened/submitted this pass) | Present in sidebar footer next to All features. |

**Global capabilities reconcile:**

| Item | Found? | Notes |
|---|---|---|
| Quick sale | Yes | Present in every list-page top bar. Full lifecycle already live-tested in `LIVE_DATA_WALKTHROUGH.md` step 8 (retail sale of Test Cream). Not re-driven visually this pass (viewport caveat above), but DOM-confirmed present. |
| Global search (⌘K) | Yes | DOM-confirmed present ("Search clients and appointments", heading "Search", placeholder "Find a client or an appointment"). Not opened/typed into this pass. |
| New appointment | Yes | Present in every list-page top bar and on Appointments' own page banner. Full lifecycle already live-tested in `LIVE_DATA_WALKTHROUGH.md` step 7. |
| Waitlist shortcut | Yes | Present in top bar in addition to the full Waitlist page. |
| Notifications | Yes | Opened live: empty state, mute toggle, mark-all-read, "View all notifications" link. |
| User/profile menu | Yes | Opened live: name/email/role header, Account, Preferences, Settings, Billing, Help, Sign out. |
| Theme mode | Yes | Opened live: toggled dark ↔ light successfully, confirmed instant and app-wide (all cards, banner, and background repainted). |
| Sidebar collapse | Yes | "Collapse menu" button present at top of the sidebar dialog; not exercised (would only affect this session's mobile-dialog presentation, not a distinct feature). |
| Print | Yes | "Print schedule" on Appointments (`/print/schedule`); Print likely also on invoices/receipts (not reached this pass — see Not Yet Covered). |
| Import CSV | Yes | Present on Clients, Inventory, Services, Appointments, plus a dedicated Settings → Import tab and a Storefront-specific "Migrate from Shopify" importer. |
| Export CSV | Yes | Present on Clients, Inventory, Services, Appointments, Transactions, Expenses, Reports, Payroll (as both Generic and Talenox-formatted CSV). |

## Everything found that was NOT on the original reconcile list

- **Client-, staff-, branch-, and service-detail pages** (`/clients/:id`, `/staff/:id`,
  `/branches/:id`, plus the service edit view) — reached via the pass-4 test records.
- **Staff → Team off-days** (`/staff/off-days`) and **Staff → View timesheets**
  (`/staff/timesheets`) — both linked from the Staff list page banner.
- **Branches → Yearly holidays** panel on the Branches page itself (dates closed every year,
  blocks booking) — distinct from a branch's own weekly Hours tab.
- **Cash drawer actions**: "Close count," "New pay-in," "New pay-out" — buttons on the Cash
  Drawer page banner, not just the read-only ledger table previously recorded.
- **Marketing sub-actions**: "Edit brand," "Send log" (`/marketing/email-log`), "Birthday emails"
  (`/marketing/birthday`), "New campaign" (`/marketing/new`) — all real routes/actions off the
  Marketing page banner, more granular than the single Marketing page previously recorded.
- **Settings → Integrations** detail: "Sending domain" (Resend-backed transactional email, "Not
  set up," default sender `noreply@mail.flowesce.com`) and "Custom booking domain" (explicit
  Growth-feature badge) — first look inside this tab; previously only listed as an unopened nav
  item.
- **Settings → Policies** detail: Booking policies with Preset, Cutoffs, Late cancel fee, No-show
  fee, Card on file, Policy text, Payment instructions sub-sections.
- **Settings → Business** page's own internal tab strip (General / Booking page / Booking rules /
  Emails / Finance) — the Business settings page is itself a multi-tab surface, not a flat form.
- **Settings → Import** as a distinct route (`/settings/import`, "Import data" / "Import from a
  CSV") separate from the per-module Import CSV links on Clients/Inventory/Services/Appointments —
  unclear yet whether it's a superset/hub or a duplicate; flagged as an open question below.
- **Booking slug / public booking URL** shown live on Settings → Business:
  `flowesce.com/book/carlington-smith-consultancy-pte-ltd`.
- **Storefront public URL** shown live: `https://carlington-smith-consultancy-pte-ltd.flowesce.com/shop`.
- **"What you call your staff"** — a business-wide noun customization (default "Stylist") that
  changes labels across the booking page and app, e.g. "Choose your Stylist."

## Plan-gating summary (Solo trial, this pass)

| Feature | Gate type | Exact evidence |
|---|---|---|
| Loyalty | **Hard paywall** | "Loyalty program (points or stamp cards that earn in-store credit) is a Growth feature." Full-page lock, "Upgrade to Growth" CTA, "See what's included" link. |
| Memberships | **Hard paywall** | "Memberships (recurring plans with monthly service credits) is a Growth feature." Same lock pattern as Loyalty. |
| Journeys | **Soft gate (build yes, activate no)** | "Journeys are part of the Growth plan... You can build one now. To set it live and start sending, upgrade to Growth." Page itself is fully open, "New journey" button live. |
| Team invites | **Soft/partial gate** | Settings → Team shows "Team invites are a Growth feature" heading, but the page itself (Expertise levels, Team members list) is otherwise open. |
| Custom booking domain | **Soft gate, informational only this pass** | "Growth feature" badge shown on Settings → Integrations; underlying form was not tested for whether it's fully blocked or just watermarked. |
| Branches (multi-branch) | **Soft gate** | "Upgrade to Growth to add more branches" shown on the Branches page even with exactly 1 branch present; the 1-branch tenant itself is fully functional. |
| Bundles, Packages, Referrals | **Not gated** | Contrary to what could reasonably be assumed from the plan-comparison marketing copy, all three are fully open and usable on the Solo trial with no lock screen at all. |

## Not yet covered by this pass (carried into a future pass, not silently dropped)

- Quick Sale, New appointment, and global-search modals were **not visually re-driven** this pass
  (viewport caveat above); their full behavioural coverage instead comes from
  `LIVE_DATA_WALKTHROUGH.md` pass 4, which is the authoritative FULLY REVIEWED source for those
  two flows. Global search itself has never been opened/typed into in any pass — genuinely open.
- Settings → Account, Billing, Team, Text & WhatsApp, Brand, Payments, Data & privacy, Import were
  opened and their headings/sections captured, but individual fields/buttons within most of them
  were not enumerated to the same depth as Business/Integrations/Policies — recorded as
  DISCOVERED, not FULLY REVIEWED, in the coverage file.
- Print flows beyond "Print schedule" (e.g. a receipt/invoice print action from an appointment or
  transaction) were not located this pass — unknown whether they exist.
- The "Feedback" sidebar button was seen but not clicked/opened.
- Role-restricted views (Manager / Receptionist / Bookkeeper / Staff) could not be tested — this
  session only has Owner access; no second account exists to compare against.
- Public-facing pages (the actual booking page, storefront shop, review-ask email content) were
  not opened from the customer side — only the admin configuration screens for them.
