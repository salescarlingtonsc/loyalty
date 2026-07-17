# PAGE_INVENTORY

Routes observed live (L) or inferred from marketing feature pages (M). Empty tenant, so
component lists reflect structure, not populated data.

| Page | Route | Src | Parent | Roles (observed) | Purpose | Key components | Gated |
|---|---|---|---|---|---|---|---|
| Onboarding: country | `/welcome/setup/country` | L | Onboarding | Owner | Set operating country (drives payments) | Country select, Continue, Skip | No |
| Dashboard | `/dashboard` | L | — | Owner+ | Command centre | Greeting, Booked today, Revenue this week, trial banner, KPI cards (Today's appts, Revenue 30d, Low-stock alerts, Unpaid deposits), Today-at-a-glance timeline, Today's Schedule, Revenue-this-week chart, "Finish setup 10%" | No |
| Loyalty | `/loyalty` | L | Catalog | Owner+ | Points/stamp config | **Locked** — upgrade card ("Loyalty… is a Growth feature") | **Growth** |
| Loyalty (mechanics) | `flowesce.com/features/loyalty` | M | — | — | Full engine spec | points/stamps, earn triggers, 3 expiry modes, credit mint, limits | — |
| Memberships (mechanics) | `flowesce.com/features/memberships` | M | — | — | Plan/renewal/dunning spec | credit pool, rollover, discount, daily renewal, Stripe SG | — |
| Referrals (mechanics) | `flowesce.com/features/referrals` | M | — | — | Referral engine spec | personal codes, attribution, qualify-on-completion, min-spend | — |
| Settings: Billing | `/settings/billing` | L | Settings | Owner | Plan & subscription | Trial banner, current plan (Solo S$25/mo trial), Monthly/Annual toggle, Solo vs Growth cards, Add payment method | No |
| Settings: Team | `/settings/team` | L | Settings | Owner | Roles & staff | Expertise levels (Senior/Junior), role tiers (Owner/Manager/Receptionist/Bookkeeper/Staff — invites Growth-gated), Team members table (Change role) | Invites Growth |
| Settings shell | `/settings/*` | L | Settings | Owner | Config hub | Tabs: Business, Account, Billing, Team, Integrations, Text & WhatsApp, Policies, Brand, Payments, Data & privacy, Import | Mixed |

## Plan feature split (from `/settings/billing`, founding annual)
- **Solo — S$18/mo founding (S$25 list):** 1 branch; unlimited staff/clients/appointments; inventory auto-deduct on completion; multi-currency expense tracking; Google Calendar sync (1); booking confirmations + reminder emails; standard reports; email support.
- **Growth — S$48/mo founding:** multi-branch; **team invites + role-based staff logins**; per-staff Google Calendar sync; custom booking domain; white-label transactional email; advanced reports + per-branch breakdowns; **smart marketing campaigns (win-back, review, anniversary)**; priority support; everything in Solo. **(Loyalty, Memberships live here.)**

## Not yet inventoried (locked or empty) — see OPEN_QUESTIONS
Clients detail view, Calendar, Appointments, Inventory, Quick Sale flow, Reports/Analytics,
Integrations, Text & WhatsApp, Payments, Data & privacy, Import, Loyalty/Membership admin config.

## Live click-through (2026-07-16, second pass — every reachable page opened)
| Page | Observed live | Relationship confirmed | Frenly status |
|---|---|---|---|
| Dashboard | greeting banner, booked-today/revenue-week, KPIs incl. low-stock + unpaid deposits, today-at-a-glance strip, schedule panel, revenue chart | dashboard reads sales+appointments+stock | ✅ equiv (no deposits — deliberate, no payments processor) |
| Calendar | Day/Week/Month grid, staff filter, colour-by status/staff, Add | appointments render on grid | ⚠️ Frenly has Week only, no staff filter |
| Appointments | list w/ search, status/staff/branch/time filters, Print schedule, CSV import/export | list ↔ calendar same data | ⚠️ Frenly list simpler; no print/CSV |
| **Requests** | **client-initiated CANCEL + RESCHEDULE approvals, auto-approve toggle, recent decisions** | portal client → change request → approval executes change | ✅ **closed in v8** — `change_requests` + `auto_approve_changes` + `request_change`/`decide_change`/`list_my_appointments` RPCs, confirmed structurally equivalent (see LIVE_DATA_WALKTHROUGH.md) |
| Waitlist | TWO queues: walk-in (manual seat) + **online (from booking page, auto-email on matching slot)** | portal → waitlist; slot-open → notification | ⚠️ Frenly waitlist is staff-entered only, no auto-email |
| Clients | search, filters, sort, **CSV import AND export**; "public bookings create client records automatically" | booking → auto client record | ⚠️ Frenly: import ✅ (Settings), export ❌; auto-create on convert (not on request) ✅ |
| Inventory | categories, branch filter, active+archived, expiry filter, low-stock-only, **bulk adjust**, CSV in/out; copy: "linking items to services auto-deducts stock on completion" | **service→product consumption map; completion deducts** | ✅ **closed in v8** — `service_products` BOM + FEFO deduction in `app.on_appointment_completed()`; live-tested against real Flowesce data (10→9 units, exact match) in LIVE_DATA_WALKTHROUGH.md |
| Services | duration, price, **deposit**, staff/branch assignment, CSV in/out | service ↔ staff ↔ branch ↔ deposit | ⚠️ Frenly: no deposit, no staff assignment |
| Bundles/Packages/Memberships/Loyalty | routes 404/paywalled on Solo trial (Growth-gated) | — | Frenly versions built from feature-page mechanics ✅ |
| All features | exits to marketing site; headline confirms composite: "finishing an appointment deducts stock used, books commission, posts to P&L" | completion → stock + commission + P&L | Frenly: completion→sale→loyalty ✅; stock-on-completion + commission ❌ |
| Top bar | global search ⌘K, Quick sale, New appointment, Waitlist buttons | shortcuts everywhere | ❌ Frenly has no global topbar shortcuts |

### Not copied on purpose
Unpaid deposits (needs card processor — deferred with Stripe), drag-drop calendar (their bug), commission/payroll (out of scope per owner).

### Recommended next build slice (from this pass)
1. ~~Cancel/reschedule request flow on portal + Requests-style approvals~~ — **done, v8**
2. ~~Service→product consumption links + deduct-on-completion~~ — **done, v8**
3. Clients CSV export; appointments print/CSV (print/CSV done for appointments in v1.5; clients export still unconfirmed)
4. Staff assignment on services + calendar staff filter; deposits (needs payments, deferred)
5. Waitlist online signup + notify (needs email/SMS — deferred with comms)
6. **New, from LIVE_DATA_WALKTHROUGH.md (2026-07-17 live-data pass):** fix `issue_gift_card` counting as revenue + earning loyalty/retention (see that file's Cross-reference section) — concrete bug, not a style gap

## Third pass — Finance / Workspace / Engagement groups (below-the-fold nav)

Trial account (Owner role, empty tenant — no branches/staff/clients created yet). All URLs
below `app.flowesce.com/<path>`, read-only navigation, no writes performed.

| Page | Purpose | Key components | Relationships stated | Gated? |
|---|---|---|---|---|
| Transactions (`/transactions`) | "Every payment taken: walk-in sales, retail, packages, and money collected on appointments (deposits, balances, no-show fees)." | All/Sales/Appointments filter tabs, date-range picker, staff + type dropdowns, Export CSV; empty state: "No transactions match — Try widening the date range or clearing a filter. New sales and appointment payments appear here as they happen." | Implicitly the ledger view for Quick Sale + appointment payments | No |
| Gift cards (`/gift-cards`) | "Sell gift cards in person. A code loads a balance a client can spend at any future visit." | Sell gift card button; "Outstanding gift-card balances" $0.00 ("Money already collected for active cards that hasn't been redeemed yet"); Gift card settings (preset amounts + Add preset, default expiry months, **"Sell online" toggle — Show gift cards on your storefront**, Terms text, Save) | Explicit toggle ties gift cards to Storefront | No |
| Cash drawer (`/cash-drawer`) | "Expected vs. actual cash for each branch. Cash payments and sales credit the drawer automatically; pay-ins and pay-outs adjust it manually." | Empty state: "No branches yet — Cash drawer tracks per-branch physical cash. Create a branch first." Set up branches CTA | Explicit: per-branch, auto-credited by cash sales; depends on Branches existing first | No (functionally blocked until a branch exists) |
| Expenses (`/expenses`) | "Track business spending across currencies." | One-time/Recurring tabs, "All expenses" filter, Filters button, Export CSV, New expense, Show voided toggle; empty state: "No expenses yet — Track what the business spends so reports show net profit, not just revenue. Multi-currency supported." | Explicit: feeds Reports net-profit calc | No |
| Reports (`/reports`) | Header only ("Reports"); date-range picker, P&L statement, Export CSV, Email reports | KPI cards: Revenue (Paid), Expenses, Net (= Revenue − Expenses), Discounts Given ("on completed appointments"), Inventory Cost Used ("Deposits: $0.00"), Commissions Earned ("Service + Product … net basis · on completion"), Cancellations (cancelled vs no-show); Revenue-by-day chart; Top Services panel; bottom tabs: By branch, By service, Commissions, Tips, Tax, Expenses, Unpaid balances, Cancellations, Inventory used | Explicit roll-up of Expenses, Inventory, Commissions, Cancellations, Discounts, Appointments — the P&L hub | No |
| Payroll (`/payroll`) | — | 404 — page does not exist on this trial | Commission math appears folded into Reports → Commissions tab instead of a standalone payroll module | 404 |
| Branches (`/branches`) | "Locations where appointments take place" | Empty state: "No branches yet — A branch is a location where appointments happen. Set its opening hours, address, and which staff and services it offers." New branch CTA | Explicit: branch owns opening hours + staff/service assignment; gates Cash drawer | No |
| Staff (`/staff`) | "Team members and their schedules." | Team off-days, Add staff; empty state: "No staff yet — Staff records hold working hours, branch and service assignments, and commission rates. Add one for each person who takes appointments." | Explicit: staff ↔ branch, staff ↔ services, staff → commission rate | No |
| Website (`/website`) | Presumed site editor (title not reached) | Stuck on "Loading editor…" after 4s+ wait, embedded editor never resolved on this trial tenant | Unknown — inconclusive | Inconclusive (looked stuck/broken, not an explicit paywall) |
| Storefront (`/storefront`) | "Sell retail products on your website. Customers reserve, you confirm and settle in person. Fulfilling an order records a sale and deducts stock." | Migrate from Shopify, View store links; Shop settings (Shop is open toggle — off by default, Offer pickup + instructions, Offer shipping, Manual payment: PayNow QR / bank transfer, mark-paid flow) | Explicit: fulfilling an order → records a sale (Transactions) + deducts stock (Inventory) | No |
| Store orders (`/store-orders`) | — | 404 — no standalone page; likely orders surface inside Storefront or Transactions instead | — | 404 |
| Marketing (`/marketing`) | "Broadcasts, birthdays, and client engagement." | Edit brand, Send log, Birthday emails, New campaign; KPIs: Reachable clients ("Have an email and aren't opted out"), Total clients, Opted out ("Excluded from sends"); Campaigns table (Campaign/Status/Recipients/Sent), empty state: "No campaigns yet. Compose your first one above." | Explicit: reachability keyed off Clients' opt-out/consent status | No |
| Reviews (`/reviews`, fallback `/review-feedback`) | — | Both 404 — no review/feedback module found under either path | — | 404 |
| Journeys (`/journeys`) | — | 404 — no automation/journey-builder module found | — | 404 |
| Promotions (`/promotions`) | "Time-windowed discounts for your public booking page." | New promotion CTA, info icon; empty state: "No promotions yet — Run a June discount, hand out a one-time SUMMER10 code, comp a service category. The strikethrough goes up on your booking page the moment the date window opens." Info panel: "v1 scope. Promotions apply to single-service public bookings. Multi-item (bundle/visit-mode) bookings ignore the code box for now. Admin manual booking still uses the per-appointment discount field on the appointment detail page. Once a promotion has been used at least once it can't be deleted (history would lose its cap counts). Pause it instead." Status legend: Live/Scheduled/Expired/Paused | Explicit: ties to public booking page, appointment-detail per-appointment discount field, and immutable usage history/cap counts | No |
| Forms (`/forms`) | "Intake & consent forms" | Add from template, New form; empty state: "No forms yet — Build a medical history, a photo-consent waiver, or any other questionnaire. Attach it to services that should require it." "Heads up" box: "Forms are informational, not a hard block. Even when a client hasn't filled their required forms, their appointment will still book and complete normally so you can onboard them in person if needed. Incomplete forms surface as a red badge on the appointment." Status legend: Live (attached to services + sending) / Paused (existing submissions intact, no new sends) | Explicit: forms attach to Services and surface as a badge on Appointments; explicitly does NOT block booking/completion | No |

**Most valuable finding:** Flowesce's whole finance stack is wired as one graph, not siloed screens — Expenses and Inventory Cost feed Reports' Net figure, Gift cards' "Sell online" toggle is literally a switch on the Storefront page, Cash drawer refuses to render until a Branch exists, and Storefront explicitly states "fulfilling an order records a sale and deducts stock" — while four nav items we expected (Payroll, Store orders, Reviews, Journeys) simply don't exist as pages, suggesting that functionality is folded into Reports/Storefront/Marketing rather than broken out.
