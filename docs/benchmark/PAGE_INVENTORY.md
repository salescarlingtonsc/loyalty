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
| **Requests** | **client-initiated CANCEL + RESCHEDULE approvals, auto-approve toggle, recent decisions** | portal client → change request → approval executes change | ❌ different: Frenly "Bookings" = new-booking requests only; no cancel/reschedule flow |
| Waitlist | TWO queues: walk-in (manual seat) + **online (from booking page, auto-email on matching slot)** | portal → waitlist; slot-open → notification | ⚠️ Frenly waitlist is staff-entered only, no auto-email |
| Clients | search, filters, sort, **CSV import AND export**; "public bookings create client records automatically" | booking → auto client record | ⚠️ Frenly: import ✅ (Settings), export ❌; auto-create on convert (not on request) ✅ |
| Inventory | categories, branch filter, active+archived, expiry filter, low-stock-only, **bulk adjust**, CSV in/out; copy: "linking items to services auto-deducts stock on completion" | **service→product consumption map; completion deducts** | ⚠️ Frenly deducts on retail sale w/ product (FEFO ✅); no service-linked consumption |
| Services | duration, price, **deposit**, staff/branch assignment, CSV in/out | service ↔ staff ↔ branch ↔ deposit | ⚠️ Frenly: no deposit, no staff assignment |
| Bundles/Packages/Memberships/Loyalty | routes 404/paywalled on Solo trial (Growth-gated) | — | Frenly versions built from feature-page mechanics ✅ |
| All features | exits to marketing site; headline confirms composite: "finishing an appointment deducts stock used, books commission, posts to P&L" | completion → stock + commission + P&L | Frenly: completion→sale→loyalty ✅; stock-on-completion + commission ❌ |
| Top bar | global search ⌘K, Quick sale, New appointment, Waitlist buttons | shortcuts everywhere | ❌ Frenly has no global topbar shortcuts |

### Not copied on purpose
Unpaid deposits (needs card processor — deferred with Stripe), drag-drop calendar (their bug), commission/payroll (out of scope per owner).

### Recommended next build slice (from this pass)
1. Cancel/reschedule request flow on portal + Requests-style approvals (their strongest ops relationship we lack)
2. Service→product consumption links + deduct-on-completion
3. Clients CSV export; appointments print/CSV
4. Staff assignment on services + calendar staff filter; deposits (needs payments, deferred)
5. Waitlist online signup + notify (needs email/SMS — deferred with comms)
