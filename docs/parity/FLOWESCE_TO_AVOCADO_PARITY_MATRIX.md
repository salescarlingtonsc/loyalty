# FLOWESCE → FRENLY PARITY MATRIX

Authoritative gap register. One row per discovered Flowesce capability. **No Flowesce feature may
disappear from this matrix.** Per the owner's Full-Coverage Audit & Parity Protocol (2026-07-17),
the default decision for every confirmed accessible feature is **"Include in parity scope."**
Any proposed omission sits in the Unapproved Omissions register (§4 below) until the owner
explicitly approves it in writing.

**Sources:** `docs/flowesce/FLOWESCE_MASTER_INVENTORY.md` + `docs/flowesce/PAGE_ACTION_COVERAGE.md`
(Pass 1 discovery), `docs/benchmark/PAGE_INVENTORY.md` (passes 1–3),
`docs/benchmark/LIVE_DATA_WALKTHROUGH.md` (pass 4, live data + exact before/after numbers).

**Frenly state as at 2026-07-17:** app v1.5 (`app/index.html`), DB through migration
`frenly_v9_giftcard_revenue` (applied). `frenly_v10_sale_policy` is **written but NOT applied** —
held at the Discovery Gate (protocol §11).

## Status vocabulary

Implementation: NOT STARTED / EXISTING AND VERIFIED / EXISTING BUT INCOMPLETE / IN DEVELOPMENT /
IMPLEMENTED / TESTED / BLOCKED
Parity: NO PARITY / PARTIAL PARITY / FUNCTIONAL PARITY / BEHAVIOURAL PARITY / FULL ACCESSIBLE PARITY
Evidence: A=confirmed accessible · B=observed not fully tested · C=inferred · D=hidden/inaccessible ·
E=blocked (permission/plan/data/destructive-risk)

---

## 1. Modules Frenly HAS — parity status against Flowesce

| ID | Flowesce module | Route | Frenly equivalent | Implementation | Parity | Precise gap |
|---|---|---|---|---|---|---|
| FL-DASH | Dashboard | `/dashboard` | `dashboard()` | EXISTING BUT INCOMPLETE | PARTIAL | Frenly lacks: low-stock KPI, unpaid-deposits KPI, today-at-a-glance strip, schedule panel. Has demographic/age charts Flowesce lacks. **Bug (QA-confirmed):** "Visits (sales)" counts membership charges as visits; gift cards correctly excluded. |
| FL-APPT | Appointments | `/appointments` | `appointmentsPage()` | EXISTING BUT INCOMPLETE | **NO PARITY — BLOCKER** | **Frenly's appointments list is permanently empty in production** (`PGRST201` ambiguous FK embed). Staff cannot see/complete/manage any booking. Also missing vs Flowesce: status/staff/branch/time filters, search. Print/CSV shipped v1.5. |
| FL-CAL | Calendar | `/calendar` | Week view inside `appointmentsPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Flowesce has Day/Week/Month + staff filter + colour-by-status/staff. Frenly has Week only, no staff filter, no Day/Month. |
| FL-REQ | Requests | `/requests` | `bookingsPage()` change-requests card | EXISTING AND VERIFIED | FUNCTIONAL | Closed in v8 (`change_requests`, `auto_approve_changes`, `request_change`/`decide_change`). Structural match confirmed. Not yet behaviourally diffed field-by-field. |
| FL-WAIT | Waitlist | `/waitlist` | `waitlistPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Flowesce has TWO queues: walk-in **and** online (from booking page, auto-email on matching slot). Frenly is staff-entered only, no online signup, no notify. Notify blocked on comms (owner-deferred). |
| FL-CLI | Clients | `/clients` | `clientsPage()`/`clientDetail()` | EXISTING BUT INCOMPLETE | PARTIAL | Frenly missing CSV **export** (import exists in Settings). Flowesce client fields Frenly lacks: pronouns, preferred contact, Instagram/TikTok/WhatsApp handles, allergies/warnings. **Bug:** "Visits on record" counts gift-card + membership sales. |
| FL-INV | Inventory | `/inventory` | `inventoryPage()` | EXISTING BUT INCOMPLETE | PARTIAL | FEFO + service→product BOM closed in v8 (live-verified 10→9). Missing vs Flowesce: categories, branch filter, archived view, expiry filter, low-stock-only filter, **bulk adjust**, CSV in/out, supplier lot/SKU, "Sell online" storefront panel, 3-way Kind (service/retail/both). |
| FL-SVC | Services | `/services` | `servicesPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Missing vs Flowesce: **deposit**, staff assignment, branch assignment, processing time, buffer before/after, per-service commission override, category, CSV in/out, Variants tab, "Show on booking page" toggle. Frenly has Bundles+Resources UI. |
| FL-BUN | Bundles | `/services/bundles` | `servicesPage()` bundles card | EXISTING BUT INCOMPLETE | PARTIAL | **Correction:** confirmed fully open on Solo trial (was previously assumed gated). Frenly has `bundles`/`bundle_items` tables + UI; not diffed against Flowesce's actual bundle flow. |
| FL-PKG | Packages | `/services/credit-packages` | `packagesPage()` | EXISTING BUT INCOMPLETE | PARTIAL | **Correction:** confirmed fully open on Solo (not gated). **Bug (QA-confirmed live, exact numbers):** $100/5-session package booked $100 `kind='retail'` revenue, +100 points, and incremented visits 3→4 **at purchase**. 10-session package = 11 visits. v10 (unapplied) fixes via `kind='package'` + policy. |
| FL-MEM | Memberships | `/memberships` | `membershipsPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Flowesce **hard Growth-paywalled (E)** — we cannot see their real implementation, so parity here is against marketing copy only, not observed behaviour. Frenly's version live-verified: 0 points earned, +60 credit correct. **Bug:** membership charge increments Visits KPI 3→4. |
| FL-LOY | Loyalty | `/loyalty` | `loyaltyPage()` | EXISTING AND VERIFIED | UNKNOWN vs Flowesce | Flowesce **hard Growth-paywalled (E)** — never observed. Frenly's own live-verified: $50 @ 1pt/$ → exactly 50 pts. Parity claim impossible until plan upgraded. |
| FL-GC | Gift cards | `/gift-cards` | `giftcardsPage()` | EXISTING AND VERIFIED | FUNCTIONAL | v9 fix live-verified in production: revenue unchanged, visits unchanged, 0 points, separate "cash collected" line, redemption → credit exact. Missing vs Flowesce: preset amounts, default expiry months, **"Sell online" storefront toggle**, terms text. |
| FL-RPT | Reports | `/reports` | `reportsPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Flowesce is a **P&L hub**: Revenue/Expenses/**Net**/Discounts/Inventory Cost Used/**Commissions**/Cancellations + tabs (By branch, By service, Commissions, Tips, Tax, Expenses, Unpaid balances, Cancellations, Inventory used) + Email reports. Frenly has revenue-by-type, loyalty flow, liabilities, CSV. **No Net, no expenses, no commissions, no tax, no tips.** |
| FL-REF | Referrals | `/marketing/referrals` | `referralsPage()` | EXISTING AND VERIFIED | FUNCTIONAL | **Correction:** confirmed open on Solo. Frenly live-verified: $10 payout on qualifying sale, exact. |
| FL-SET | Settings | `/settings` | `settingsPage()` | EXISTING BUT INCOMPLETE | PARTIAL | Flowesce has **11 tabs** (Business/Account/Billing/Team/Integrations/Text & WhatsApp/Policies/Brand/Payments/Data & privacy/Import) + Business sub-tabs (General/Booking page/Booking rules/Emails/Finance). Frenly has ~1 page: business info, module toggles, team roster, CSV import. **Data & privacy is PDPA-relevant ⚖️.** |

## 2. Modules Frenly does NOT have at all — NO PARITY

| ID | Flowesce module | Route | Confirmed behaviour (evidence) | Frenly | Blocking dependency |
|---|---|---|---|---|---|
| FL-BRANCH | **Branches** | `/branches` | A — Location entity: opening hours, address, staff+service assignment. **Gates Cash drawer.** Multi-branch itself is Growth-gated but the page/entity is open. | **NONE.** `businesses` row *is* the single location. | Foundation — protocol §12 puts branch model at position 1. Many rows below depend on it. |
| FL-STAFF | **Staff** | `/staff` | A — Records hold working hours, branch + service assignment, **commission rates** (two-rate split: service % vs product/sale %), calendar colour, active flag. Sub-pages: timesheets, team off-days. | Partial: `staff` table + Settings roster + v7 invites (5 roles). **No schedules, no service assignment, no commission, no timesheets, no off-days.** | Depends on Branches. |
| FL-TRX | **Transactions** | `/transactions` | A — Payment ledger distinct from sales: "every payment taken… deposits, balances, no-show fees." Filters All/Sales/Appointments, date range, staff, type, Export CSV. | **NONE.** Frenly's `sales` conflates *sale* and *payment*. | Requires the completion≠payment split (FL-CHECKOUT). |
| FL-CHECKOUT | **Checkout / payment decoupling** | appointment modal | A — **Live-verified pass 4:** completion deducts stock + counts visit but creates **no** transaction; a separate Checkout (Full/partial, method, amount) creates the transaction, recognises revenue, credits drawer. "FULLY PAID" badge; "balance pending" state. | **NONE.** `on_appointment_completed()` inserts the sale at completion; no unpaid state exists. | **Architectural fork.** Largest single gap. Affects Transactions, Reports, Cash drawer, deposits. |
| FL-DRAWER | **Cash drawer** | `/cash-drawer` | A — Expected vs actual cash per branch; cash sales auto-credit (live-verified $0→$50→$75→$100); manual pay-in/pay-out; close-count flow (untested, Pass 2). | **NONE.** | Depends on Branches. |
| FL-EXP | **Expenses** | `/expenses` | A — One-time + recurring tabs, multi-currency, void toggle, Export CSV. Feeds Reports **Net**. | **NONE.** Frenly cannot compute net profit. | Feeds FL-RPT Net. |
| FL-PAYROLL | **Payroll** | `/reports/payroll` | A — **CORRECTION: this page is real.** Earlier pass wrongly logged 404 by guessing `/payroll`. | **NONE.** Commission is "out of scope per owner" in CLAUDE.md — **that exclusion predates this protocol and is now an Unapproved Omission (§4).** | Depends on Staff commission rates. |
| FL-WEB | **Website** | `/website` | E — Site builder; **genuinely screen-size-gated** by Flowesce itself ("needs a desktop or laptop"). Not broken. Contents unknown (D). | **NONE.** (Separate marketing site exists on Vercel project `loyalty`, not a builder.) | Pass 2 on a desktop viewport. |
| FL-STORE | **Storefront** | `/storefront` | A — Public retail listing. "Fulfilling an order records a sale and deducts stock." Inventory items carry a per-item "Sell online" panel; gift cards carry a "Sell online" toggle. | **NONE.** Frenly's portal is booking-only. | Depends on Inventory + Checkout. |
| FL-ORDERS | **Store orders** | `/storefront/orders` | A — **CORRECTION: real page.** Earlier pass wrongly logged 404 by guessing `/store-orders`. Fulfilment flow (untested, Pass 2). | **NONE.** | Depends on Storefront. |
| FL-MKT | **Marketing** | `/marketing` | A — Reachable/opted-out KPIs (live: 1/1 reachable), campaigns, email log, birthday emails. | **NONE.** | Comms owner-deferred (WhatsApp/SMS) — but **email campaigns are a separate capability and are not covered by that deferral.** |
| FL-FEEDBACK | **Review feedback** | `/marketing/feedback` | A — **CORRECTION: real page.** Earlier pass wrongly logged 404 by guessing `/reviews`. | **NONE.** | — |
| FL-JOURNEY | **Journeys** | `/marketing/journeys` | A/E — **CORRECTION: real page.** Buildable; **activation** is plan-gated (soft gate). | **NONE.** | — |
| FL-PROMO | **Promotions** | `/promotions` | A — Affects checkout pricing, marketing eligibility, reporting. | **NONE.** Frenly has retention rewards (discount%/free item/credit) but no promotion/discount-code engine. | Depends on Checkout. |
| FL-FORMS | **Forms** | `/forms` | A — Intake/consent forms attachable to services; badge on appointments. **A form named "test" already exists in the tenant** (not created by us — origin unknown, D). | **NONE.** | **PDPA-relevant ⚖️** (consent capture). |
| FL-RES | **Resources** | `/resources` | A — Bookable rooms/equipment; services declare required resources; processing time holds them. | Tables exist (v6) + UI in `servicesPage()`. **Not wired to booking availability.** | EXISTING BUT INCOMPLETE. |
| FL-ALLFEAT | **All features** | `/all-features` | A — Not a directory: a **page-visibility manager** with per-page eye-toggle, grouped MAIN/CATALOG/FINANCE/WORKSPACE/ENGAGEMENT. | Frenly has `enabled_modules` per business — conceptually close, but owner-set at onboarding, no per-page hide/show UI. | PARTIAL. |
| FL-GLOBAL | **Global search (⌘K)** | top bar | B — Present in DOM; not driven this pass (viewport). | **NONE.** | — |
| FL-QSALE | Quick sale (top bar) | top bar | A — Live-tested pass 4. | Exists as `salesPage()` form, **not a global shortcut**. | PARTIAL. |
| FL-NOTIF | Notifications | bell | A — Empty state, mute toggle, mark-all-read, view-all. | **NONE.** | — |
| FL-THEME | Theme mode | profile menu | A — FULLY REVIEWED. | **NONE.** | Cosmetic. |
| FL-DEPOSIT | Deposits | service + appt | A — Per-service "require deposit on booking"; dashboard unpaid-deposits KPI; Reports "Deposits: $0.00". | **NONE.** | Blocked on payments processor (Stripe owner-deferred). |
| FL-TIPS / FL-TAX | Tips, Tax | Reports tabs | B — Tabs confirmed present; contents not read. | **NONE.** Frenly has `businesses.currency`, no GST/tax engine. | **SG GST ⚖️.** |

## 3. Where Frenly EXCEEDS Flowesce (do not regress)

| Capability | Note |
|---|---|
| Points **expiry** engine (3 modes, batches, daily pg_cron sweep) | v3. Flowesce's loyalty is paywalled — unknown whether they match. |
| Demographic analytics (gender, age bands) | Dashboard charts. No Flowesce equivalent seen. |
| Retention programs (visit-frequency → discount/free-item/credit) | v2. Live-verified: fires exactly at goal, not early. |
| `audit_log` + RLS on every table | Flowesce's appointment Activity log only records creation — status changes are **not** logged (pass-4 finding). |
| Industry-driven module presets | 7 industries auto-select module sets. |

## 4. UNAPPROVED OMISSIONS REGISTER

Per protocol §10 these are **not approved** and must not be treated as approved. Each needs the
owner's explicit written decision.

| # | Item | Current state | Why it's here |
|---|---|---|---|
| UO-1 | **Commission / Payroll** (FL-PAYROLL, FL-STAFF commission rates, Reports→Commissions tab) | `CLAUDE.md` records "commission/payroll — out of scope per owner" | That exclusion was given **before** this protocol. Protocol §10 says prior informal exclusions don't carry. Also: the page is real, not a 404 as previously reported. **Needs re-confirmation.** |
| UO-2 | **Stripe / payments processor** (FL-DEPOSIT, FL-CHECKOUT payment methods) | Owner-deferred, explicit | Deferral was explicit and recent — likely still stands, but it now blocks Transactions, Cash drawer, Deposits and the Checkout split. Recording the **consequence**, not challenging the decision. |
| UO-3 | **WhatsApp/SMS comms** (FL-WAIT online notify, FL-MKT) | Owner-deferred, explicit | Same. Note: **email** campaigns/journeys/birthday emails are a *separate* capability the deferral arguably doesn't cover. Needs clarification. |
| UO-4 | **Multi-branch** (FL-BRANCH, FL-DRAWER) | Never scoped | Protocol §12 puts the branch model at foundation position 1. Frenly has no branch entity at all. This is the single largest structural omission. |
| UO-5 | **Storefront / Store orders / Website builder** | Never scoped | CLAUDE.md scopes Frenly as "loyalty-only… don't clone salon OS surface" — **directly contradicts** this protocol's "complete parity for every accessible feature." Needs the owner to reconcile the two instructions. |
| UO-6 | **Completion ≠ payment split** | Never scoped | Architectural. Everything financial hangs off it. |

## 5. Contradiction requiring owner resolution

`CLAUDE.md` currently says: *"Should NOT be duplicated / out of scope: Salon-specific surface
(calendar, booking, inventory, POS, packages) — Avocado is loyalty-only."*

The Full-Coverage Parity Protocol says: *"complete functional and behavioural parity for every
feature accessible through the account… Do not decide that a module is unimportant."*

**These cannot both be true.** Frenly has already built calendar/booking/inventory/packages
(so the older line is stale in practice), but Storefront, Website, Payroll and Branches sit
exactly on the fault line. Flagged rather than resolved unilaterally — see UO-5.

## 6. Coverage as at Pass 1

| Metric | Count |
|---|---|
| Flowesce modules discovered | 33 reconcile-list items, **all found real** + ~12 not on the list |
| Pages/routes/modals recorded | ~44 (43 coverage IDs) |
| Genuine 404s | **0** (four prior "404" claims were our own wrong URLs) |
| Hard paywalls (E) | 2 — Loyalty, Memberships |
| Soft gates | Journeys activation, team invites, custom booking domain, multi-branch |
| FULLY REVIEWED | 2 |
| PARTIALLY REVIEWED | ~18 |
| DISCOVERED | ~19 |
| BLOCKED | 3 |
| Frenly modules with NO PARITY | **22** (§2) |
| Unapproved omissions | **6** — must reach 0 before any full-parity claim |

**Discovery Gate: NOT PASSED.** Pass 2 (workflow testing) and Pass 3 (cross-module verification)
have not been run. Role-permission matrix cannot be completed — only one account (Owner) exists;
no second role available to test against.
