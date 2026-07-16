# MODULE_INVENTORY

Every module observed in the Flowesce console, with the loyalty-relevant ones expanded.
Legend: **[Core-Loyalty]** = directly benchmarked for Avocado · **[Salon-only]** =
context, not reproduced in Avocado · **[Shared]** = platform plumbing Avocado also needs.

## Left-nav modules
| Module | Route | Type | Purpose | Gated? |
|---|---|---|---|---|
| Dashboard | `/dashboard` | [Shared] | Command centre: KPIs, today's schedule, alerts | No |
| Calendar | `/calendar` | [Salon-only] | Appointment calendar, drag-reschedule | No |
| Appointments | `/appointments` | [Salon-only] | Appointment list/management | No |
| Requests | `/requests` | [Salon-only] | Inbound booking requests inbox | No |
| Waitlist | `/waitlist` | [Salon-only] | Cancellation-recovery waitlist | No |
| Clients | `/clients` | [Core-Loyalty] | Member records — the loyalty subject | No |
| Inventory | `/inventory` | [Salon-only] | Stock w/ batch expiry (FEFO), auto-deduct | No |
| Services | `/services` (Catalog) | [Salon-only] | Service catalogue + pricing | No |
| Bundles | `/bundles` (Catalog) | [Salon-only] | Service bundles | No |
| Packages | `/packages` (Catalog) | [Salon-only] | Prepaid multi-session packages | No |
| **Memberships** | `/memberships` (Catalog) | **[Core-Loyalty]** | Paid recurring plans w/ credits + discount | **Growth** |
| **Loyalty** | `/loyalty` (Catalog) | **[Core-Loyalty]** | Points / stamp-card program → in-store credit | **Growth** |
| Resources | `/resources` (Catalog) | [Salon-only] | Bookable rooms/equipment | No |
| All features | `/features` | [Shared] | Feature index | No |
| Feedback | `/feedback` | [Shared] | Product feedback | No |
| Settings | `/settings/*` | [Shared] | Admin/config (see below) | Partly |

Top bar: global Search (⌘K), **Quick Sale** (walk-in/retail sale — a loyalty **earn trigger**), New appointment, Waitlist, theme, notifications.

## Settings sub-modules
Business · Account · **Billing** (plans/tiers) · **Team** (roles) · **Integrations** ·
**Text & WhatsApp** (comms) · Policies · Brand · **Payments** (Stripe/SG) ·
**Data & privacy** (PDPA-relevant) · **Import** (CSV migration).

---

## Core-Loyalty modules — detail

### Loyalty (`/loyalty`) — Growth
- **Does:** free-to-join **points** (1 pt per $1, redeem at owner-set thresholds → in-store credit, e.g. 800 pts → $20) **or** **stamp card** (every Nth service visit free). Config on one admin page.
- **Why:** drive repeat visits with a reward the client can actually spend (real credit, not vanity points).
- **Who:** owner/manager configures; front desk does nothing (auto); client sees read-only balance in portal + a loyalty card on the client page.
- **Inputs:** completed appointments, Quick Sales (walk-in/retail). **Outputs:** points balance; on redeem, an in-store **credit** entry ("loyalty reward").
- **Depends on:** completion events (Appointments, Quick Sale), the **credit ledger**, Client record, client portal. Daily **expiry sweep** job.
- **Rules (verified from feature page):** earns on **headline service price only** today (add-on retail + discount-netting = fast-follow, "never over-earns"); **3 expiry modes** (none / inactivity-rolling / fixed-from-earn, drained oldest-first); stamp reward **not clawed back** if triggering appointment later cancelled; **no payment processor** (only mints credit → region-agnostic).
- **Business problem solved:** retention without manual punch cards/spreadsheets.

### Memberships (`/memberships`) — Growth
- **Does:** paid recurring plan (monthly/annual) = **service-credit pool** (scoped to chosen services) + optional **standing discount** (composes largest-wins, never stacks). Rollover toggle.
- **Enroll:** one transaction creates membership, drops first-period credits, records first charge, **books a `sale` of kind `membership`** into the P&L.
- **Renewals:** **daily job** at period boundary (tenant timezone) refreshes credits + records charge; honors cancel-at-period-end; skips paused; never double-charges. **Manual** = posts due charge (collect in person, all regions); **Singapore** = Stripe off-session auto-charge + **dunning** across grace window → lapse + email on failure.
- **Depends on:** Client, credit/sales ledger, Payments (Stripe, SG), Reports/P&L.
- **Business problem solved:** predictable recurring revenue; locks in regulars.

### Referrals (feature page; not a separate nav item — runs off Loyalty/credit) — Growth
- **Does:** each client gets a **personal referral code** on a portal share card. Friend books with code → **attributed immediately**; reward **holds** until friend **completes first qualifying visit**, then **in-store credit** lands on referrer automatically.
- **Qualifiers:** min-spend on first visit, reward amount, reward expiry; **off by default** per business. One reward per first visit (issued once).
- **Depends on:** Client, credit ledger, completion event, client portal.
- **Business problem solved:** turns word-of-mouth into tracked, **self-funding** growth (pays only after real revenue booked).

### Reviews / reputation (feature page) — Growth marketing
- **Does:** routes happy clients to public Google review, unhappy to a private inbox (reputation gating). Evidence lighter — from marketing pages; verify live.

### Clients (`/clients`) — the member record
- Holds profile + (per feature pages) a **loyalty card** and **membership card** side by side, credit balance, history. This is Avocado's central "member" entity. Live fields not fully enumerable (empty tenant) — see OPEN_QUESTIONS.

---

## Shared plumbing Avocado also needs
- **In-store credit ledger** — the spine: refunds, gift cards, loyalty rewards, referral rewards, membership charges all flow through it. **System of record for balances.**
- **Sales/transactions** — completion + Quick Sale are the earn triggers; each membership charge writes a `sale`.
- **Payments (Stripe, SG-gated)** — needed only for membership auto-charge; loyalty/referrals need no processor.
- **Comms (email today; SMS "building"; WhatsApp later)** — birthday auto-send + smart campaigns.
- **Import (CSV)** — migration from Mangomint/Fresha/Acuity.
- **RBAC (Team)** — Owner/Manager/Receptionist/Bookkeeper/Staff.
