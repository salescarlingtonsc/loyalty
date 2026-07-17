# LIVE_DATA_WALKTHROUGH

Fourth pass on Flowesce (Solo trial, tenant "CARLINGTON SMITH CONSULTANCY PTE. LTD.",
Owner "Zeph Lee"). Unlike passes 1–3 (documented in `PAGE_INVENTORY.md`, read-only,
empty tenant), this pass **created real test data and executed full feature
lifecycles**, recording exact before/after numbers at each step. All test data below
is obviously fictitious (see naming). No real names/phones/emails were entered, no
payment/card details were entered anywhere, and no external email/SMS was sent (the
one appointment's "Email confirmation to client" checkbox was deliberately unchecked
before booking).

Session date in-app: dashboard greeting read "Thursday, Jul 16" and server-side
transaction timestamps landed on `2026-07-16 18:1x`, one calendar day behind the
`2026-07-17` "today" used elsewhere in this project. This looks like a UTC-vs-local
display offset (app server clock vs. the browser's "Jul 17" default when opening the
booking modal) rather than a data error — flagged here once so the timestamps below
aren't mistaken for a mistake on our part.

## Test data created (for reference)

| Entity | Value |
|---|---|
| Branch | **Test Branch** — no address/phone/email, tax rate = business default, all 7 days open 09:00–17:00, Active |
| Staff | **Test Staff** — assigned to Test Branch, no title, no commission override (blank = falls through to business default / none), Active |
| Service | **Test Facial** — $50.00, 45 min, no category, no deposit, assigned to Test Branch + Test Staff, no resources, no forms attached |
| Inventory item | **Test Cream** — Kind = Both (service-consumed AND retail-sellable), Unit = piece, Branch = Shared (all branches), starting stock batch = **10 piece**, expiry **June 2027**, low-stock threshold 3, cost/unit $5.00, retail price $25.00, Active, sales-tax on |
| Service→product link | Test Facial requires **1 piece of Test Cream per appointment** (configured on the Service's own "Inventory" tab — see step 5) |
| Customer | **Test Customer QA** — qa-test@example.invalid, +65 9000 0001 |
| Gift card sold | Code `GIFT-ETEV-5WJB`, $25.00, purchaser = Test Customer QA |

Record IDs (for anyone re-opening this tenant): client
`4135f4b4-fce2-4679-862a-c9b0f91e004d`, service `c93061b4-63cf-4129-97de-6d9f30bdb369`,
inventory item `e4340995-6d34-4aa3-b4d9-5cb400be29d5`.

---

## Step 1 — Branch

**Action:** Branches → New branch → name "Test Branch" → Hours tab → "Open all days"
(applies the 09:00–17:00 default to Sun–Sat) → Create branch.

**Form fields observed (General tab):** Branch name*, Address, Phone, Email, Tax
rate (%) (placeholder "Business default"; helper text: "Tax rate overrides the
business default. Blank inherits it; 0 is a valid override"), Active toggle
("Accepting bookings, shown on the public booking page"). **Hours tab:** per-day
checkbox + start/end time + "Add break" + "Copy to all", plus "Open all days" /
"Close all days" shortcuts.

**Before:** 0 branches ("No branches yet").
**After:** 1 branch ("1 location"). Branch card immediately showed a live
Staff/Today/This-month stat widget (0 / 0 / $0.00) and an **"Upgrade for
multi-branch"** prompt appeared next to the page title.

**Verdict: relationship confirmed** — creating a branch is what unlocks the
multi-branch upsell surface and (see step 7) the Cash-drawer page.

---

## Step 2 — Staff

**Action:** Staff → Add staff → name "Test Staff" → Branches tab → check Test Branch
→ Schedule tab → "Open all days" → Commission tab (left blank) → Create staff.

**Form fields observed:** Profile (Full name*, Email, Phone, Title, Calendar color,
Active), Branches (checkbox list), **Services tab said "Add a service first"**
(empty at this point since no service existed yet), Schedule (same weekly-hours
widget as branches), Commission (Service commission %, Product/sale commission %,
Commission-starts-on date — explicit two-rate split: service commission is separate
from "Product / sale commission," which "applies to every sale this staff rings up
(retail, package, walk-in)").

**Before:** 0 staff ("No staff yet").
**After:** 1 staff member, correctly showing "Test Branch" on its card. Onboarding
progress ("Finish setup") jumped 10% → 30% → 60% across steps 1–2.

**Verdict: relationship confirmed** — staff↔branch assignment works immediately;
staff↔service assignment is gated until a service exists (bidirectional dependency
between Staff and Services, exactly as `PAGE_INVENTORY.md` inferred from empty-state
copy).

---

## Step 3 — Service

**Action:** Services → New service → name "Test Facial", duration 45, price 50.00 →
Staff tab → assign Test Staff → Create service.

**Every field the form asked for**, by tab:
- **Service:** Service name*, Description, Category (optional dropdown), Duration
  (min), Price, Active toggle, "Show on booking page" toggle.
- **Advanced:** "Require a deposit on booking" toggle (off by default — deposits are
  a real field on this form, contra nothing), "Apply sales tax" toggle, Commission
  rate % ("Overrides each staff member's default for this service. Leave blank to
  fall through."), Processing time (min) ("Mid-booking wait... resources stay held"),
  Buffer before / after (min).
- **Branches:** "Offered at branches" — defaulted to "All branches (1)".
- **Staff:** "Staff who perform this" — pill list, click to toggle.
- **Resources:** "Required resources" (empty — no resources created in this tenant).
- **Forms:** "Pick the intake or consent forms..." — **a form named "test" was
  already present in this picker**, despite the tenant otherwise reading as empty
  everywhere else. Not created by us, not selected. Noted as a minor surprise; not
  investigated further since it's outside this task's scope.
- **Inventory / Variants** — these two tabs **only appear after the service is
  saved once** (they were absent from the "New service" creation wizard, and only
  showed up when we reopened the saved "Test Facial" record). This is exactly where
  the service→product link lives — see step 5.

**Before:** service list showed the warning "This service can't be booked yet. Assign
at least one staff member." with preview "1 branch · 0 staff".
**After:** warning disappeared the instant a staff member was checked; preview read
"1 branch · 1 staff". List view shows a dedicated **INVENTORY** column (was "–").

**Verdict: relationship confirmed** — a service without staff cannot be booked;
assigning staff is what flips it live. Deposit, staff-assignment, and branch fields
are all real, per-service settings (matches `PAGE_INVENTORY.md`'s inference from the
Services list columns).

---

## Step 4 — Inventory

**Action:** Inventory → New item → name "Test Cream", Kind = **Both**, toggled
"Track expiry on this item" on, quantity received 10, expiry month **June 2027**,
low-stock threshold 3, cost/unit 5.00, retail price 25.00 → Create item.

**Every field the form asked for:** Item name*, Category, Unit (default "piece"),
Branch (default "Shared (all branches)"), **Kind — a 3-way choice: Service ("consumed
when an appointment completes"), Retail ("sold to clients via Quick Sale"), or Both
("used in services AND sold at retail")** — this is the field that determines which
consumption path(s) apply. "Track expiry on this item" toggle ("Capture your
starting stock as a batch with an expiry month. Future shipments add new batches;
auto-deduction drains the soonest-expiring first" — i.e. FEFO, stated explicitly in
the UI copy). With expiry tracking on, a "First batch" sub-form appears: Quantity
received, Cost per unit (this batch, optional), Expiry month, Received on (defaulted
to today), Supplier lot/SKU. Then: Low-stock threshold, Cost per unit (USD), Retail
price (USD) ("Editable per line in Quick Sale"), Supplier, Active, Apply sales tax,
Notes. A separate "Sell online" / storefront-listing panel (listing name, description,
highlights, category, photos) sits below the core form — confirms retail items are
also directly storefront-publishable from this same record.

**Before:** 0 inventory items ("No inventory yet").
**After:** 1 item, **Stock = 10 piece** exactly (starting quantity, recorded exactly
as created, not rounded), Threshold 3, Next expiry Jun 2027, Cost $5.00, Price $25.00,
Status "In stock".

**Verdict: relationship confirmed** — starting quantity is captured exactly as a
dated batch, and the "Both" kind is what makes an item eligible for both consumption
paths tested in steps 7–8.

---

## Step 5 — Link service → product

**Where it's configured:** NOT on the "New service" wizard, and NOT on the inventory
item's own detail page (its Overview tab goes straight from Notes/Save-changes to the
"Sell online" storefront section — no service-link section there). It is configured
on the **saved Service's own "Inventory" tab** (`Services → Test Facial → Inventory`),
which only appears after the service already exists.

**Action:** Test Facial → Inventory tab → "Inventory required per appointment" →
picked Item = Test Cream, Qty = 1 → Add → **Save changes**.

**Exact copy on that tab:** "Inventory required per appointment — When this service
is marked completed, these quantities are deducted." One item/qty row was added
("Test Cream — 1 piece") with a delete icon; a "Saved." confirmation banner appeared
after clicking Save changes.

**Before:** Services list "INVENTORY" column showed "–" for Test Facial.
**After:** Services list "INVENTORY" column showed "1".

**Verdict: relationship confirmed** — the link is real, configured per-service (not
per-item), and is exactly what step 7 exercises.

---

## Step 6 — Customer

**Action:** Clients → Add client → Full name "Test Customer QA", Email
qa-test@example.invalid, Phone +65 9000 0001 → Create client. (One retry was needed:
the first keystroke into the name field was dropped by a click/type race, producing
"est Customer QA" — caught and corrected before saving; noted only as a UI-automation
artifact, not a Flowesce bug.)

**Form fields observed:** Full name*, Email, Phone, Date of birth, Pronouns, Gender,
Preferred contact, Instagram/TikTok/WhatsApp handles, Notes, Allergies/warnings. No
branch-assignment field — clients are not branch-scoped.

**Before:** 0 clients ("No clients yet").
**After:** 1 client. Client-detail baseline (recorded here as the true "before" for
step 7): **Visits 0, Total spent $0.00, Last visit "–", Credit on file $0.00, no
prepaid-session credits.**

**Verdict: relationship confirmed** (client creation itself, trivially) — baseline
numbers captured for the lifecycle test below.

---

## Step 7 — Full appointment lifecycle

**Action:** New appointment → Client = Test Customer QA, Service = Test Facial, Staff
= Any available (auto-assigned Test Staff), date Fri Jul 17 2026, slot 10:00 →
unchecked "Email confirmation to client" → Book appointment. Then walked the full
status machine one action at a time, capturing before/after at **every** transition:

### 7a. Booked → Confirmed → Arrived
Appointment detail modal actions: **Confirm**, **Mark arrived**, **Cancel**,
**No-show**, **Checkout** are all offered from a "booked" appointment; **Confirm**
and **Mark arrived** are simple status flips with no side effects on
inventory/transactions/reports (verified — none of those pages changed after either
click). The appointment detail modal's own status badge and Payment/Balance box
appeared **stale immediately after each action** (still showed the old badge/amount
for a beat) even though a success toast fired instantly and the underlying
Appointments list updated correctly — a same-page UI staleness quirk, not a data
delay.

### 7b. Marked completed (before any payment)
**Action:** clicked "Mark completed" on the "arrived" appointment.

| Check | Before | After (immediately, no manual refresh) | Verdict |
|---|---|---|---|
| Appointment status | arrived | **completed** | confirmed |
| Payment/Balance box | — | still "$50.00 balance — Pending" ("Closed, but there's an outstanding balance. Record the payment below.") | **completion ≠ payment**, confirmed as two distinct events |
| Inventory: Test Cream stock | 10 piece | **9 piece** | confirmed — exactly 1 unit, matching the configured qty |
| Transactions count | 0 | 0 | **NOT** yet created by completion alone |
| Cash drawer | no activity | no activity | unchanged — no payment yet |
| Reports → Inventory Cost Used | $0.00 | **$5.00** | confirmed, immediate (no refresh/delay — the $5.00 = 1 unit × $5.00 cost) |
| Reports → Revenue (Paid) | $0.00 | $0.00 | unchanged — revenue is payment-gated, not completion-gated |
| Reports → Top Services | "No completed appointments yet" | still "No completed appointments yet" | see date-range note below |
| Client → Visits | 0 | **1** | confirmed |
| Client → Last visit | "–" | **Jul 17** | confirmed |
| Client → Total spent | $0.00 | $0.00 | unchanged — payment-gated |
| Appointment "Activity" log | — | **only ever showed "Appointment created"** — Confirm/Arrived/Completed were never logged as separate Activity entries, despite each producing a success toast | audit-trail gap in Flowesce itself, worth flagging |

**Reports date-range subtlety (real finding, not a bug in our test):** with the
default report range "Jun 16 – Jul 16, 2026" (i.e. ending the day *before* the
appointment's Jul 17 calendar date), the top **Revenue (Paid)** KPI card still
correctly picked up the $5.00 Inventory-Cost-Used change (keyed off something inside
the range), but the **Top Services** donut and the **By-branch** breakdown table
both showed zero/empty. Extending the range's end date to include Jul 17 made Top
Services and By-branch populate correctly (Test Branch → 1 completed appointment →
$50.00 once paid). **Conclusion: different Reports widgets key off different date
fields** (most likely payment/transaction timestamp vs. appointment calendar date),
so a report window that excludes an appointment's own calendar day can under-report
completed-appointment counts even while the top-line revenue number looks right.

### 7c. Checkout (cash, full payment)
**Action:** Checkout → Full payment, Method = Cash, Amount $50.00 → Charge $50.00.

| Check | Before checkout | After checkout | Verdict |
|---|---|---|---|
| Appointment payment badge | Balance $50.00 Pending | **"FULLY PAID"** | confirmed |
| Transactions count | 0 | **1** (row: Appointment / Full / Test Facial / Test Customer QA / Test Staff / cash / $50.00) | confirmed |
| Reports → Revenue (Paid) | $0.00 | **$50.00** | confirmed |
| Reports → Net | $0.00 | **$50.00** | confirmed |
| Cash drawer → Expected in drawer | $0.00 | **$50.00** (Cash in +$50.00) | confirmed, automatic — no manual pay-in needed |
| Client → Total spent | $0.00 | **$50.00** | confirmed |

**Verdict overall for step 7: relationship confirmed, with one important nuance** —
"finishing an appointment deducts stock" is true the moment status flips to
completed; "...and posts to P&L/creates a transaction/credits cash drawer" is **only**
true once a separate Checkout/payment step is also done. The two are decoupled, not
one atomic action.

---

## Step 8 — Direct Quick Sale path (second, distinct stock-deduction path)

**Action:** Quick sale (top bar) → client = Test Customer QA → Retail tab → Test
Cream ($25.00, "9 in stock" shown in the picker) → Cash → "Exact" → Charge $25.00.

| Check | Before | After | Verdict |
|---|---|---|---|
| Inventory: Test Cream stock | 9 piece | **8 piece** (same-page view still showed "9" right after the "Sale recorded" toast — a **fresh navigation/reload was required** to see the real number; the underlying data itself was already correct, only the already-rendered list didn't auto-refresh) | confirmed — second, independent deduction path (direct retail sale, no appointment involved) |
| Transactions count | 1 | **2** (new row: Sale / Retail / Test Cream / Test Customer QA / cash / $25.00) | confirmed |
| Reports → Revenue (Paid) | $50.00 | **$75.00** | confirmed |
| Reports → Inventory Cost Used | $5.00 | **$10.00** (i.e. $5 service-linked consumption + $5 retail-sale cost basis — this metric sums cost basis across **both** consumption channels, not just service-linked ones as its own label might imply) | confirmed |
| Cash drawer | $50.00 | **$75.00** | confirmed, automatic |
| Client → Visits | 1 | 1 (unchanged — a retail purchase is not counted as a "visit") | as expected |
| Client → **Total spent** | $50.00 | **still $50.00, NOT $75.00** (re-verified via a hard navigation through Dashboard → client page, not a cache artifact) | **relationship NOT confirmed — genuine gap**: the $25 retail Quick Sale is correctly attributed to "Test Customer QA" in Transactions/Cash-drawer/Reports, but is **excluded from the client's own lifetime "Total spent" figure**, which appears to only sum appointment-linked payments. |

**Verdict: both stock-deduction paths (service-linked consumption on completion, and
direct retail Quick Sale) are real and independently confirmed working** — but the
client-level spend aggregate has a real, reproducible blind spot for the retail path.

---

## Step 9 — Stretch items

### 9a. Gift card sale
**Action:** Gift cards → Sell gift card → $25.00 → Cash → Purchaser = Test Customer
QA → Sell gift card. Modal copy up front: *"Loads a balance onto a new code. Recorded
as a gift card sale, not revenue, until it's redeemed."* Code issued: `GIFT-ETEV-5WJB`.

| Check | Before | After | Verdict |
|---|---|---|---|
| Outstanding gift-card balance | $0.00 | **$25.00** (updated live on the same page this time, no reload needed — inconsistent with the Inventory page's same-page staleness in step 8) | confirmed |
| Transactions count | 2 | **3** (new row: Sale / **Gift card sold** / Test Customer QA / cash / $25.00) | confirmed — it does appear in the transaction ledger |
| Reports → Revenue (Paid) / Transactions "Net Revenue" | $75.00 | **still $75.00, unchanged** (Sales/Appointments breakdown also unchanged) | **confirms the disclaimer exactly**: gift-card sale is recorded as a ledger entry but deliberately excluded from revenue recognition |
| Cash drawer | $75.00 | **$100.00** | confirmed — real cash was collected and hits the drawer regardless of revenue recognition |

**Verdict: relationship confirmed**, and it's a clean, precise illustration that
Flowesce distinguishes "cash physically collected" from "revenue recognized" as two
separate concepts feeding two separate ledgers.

### 9b. Network requests at the moment of "Mark completed"
Captured via `read_network_requests` immediately before/after each status action.
For **Mark arrived**, the mutation was clearly a **single `POST
https://app.flowesce.com/appointments`** (Next.js Server Action pattern — the POST
targets the current page URL, not a separate REST/RPC endpoint), plus one unrelated
`POST /ingest/i/v0/e/...` analytics/tracking call (PostHog-style, fires on every
click regardless of business logic). For **Mark completed**, the equivalent mutation
POST was **not distinctly captured** in the read window that followed (the buffer
showed ~30 prefetch GETs for sidebar routes plus the analytics POST, but no visible
second POST to `/appointments`) — most likely a timing/tool artifact rather than a
different mechanism, since the toast, status badge, and every downstream number
(inventory, reports) all changed correctly and atomically. **Conclusion (medium
confidence, not fully proven): status-change mutations are single server-side calls
per action** — I could not conclusively prove whether stock-deduction and the
(eventual, on-Checkout) sale-creation happen inside that same one call or as
follow-on calls, because the completion click's own mutation request wasn't cleanly
isolated in this pass.

### 9c. Loyalty / Retention / Marketing gating
- **Loyalty** (`/loyalty`): **still Growth-plan-gated**, unchanged from the earlier
  read-only passes — lock icon, "Loyalty program (points or stamp cards that earn
  in-store credit) is a Growth feature," "Upgrade to Growth" CTA. Populating the
  tenant with real branches/staff/services/clients/sales did **not** unlock it; the
  gate is purely plan-tier, not data-completeness.
- **Marketing** (`/marketing`): confirmed reachable (not gated), and its KPI cards
  now correctly reflect the real client we created: Reachable clients 1 (100% of
  clients), Total clients 1, Opted out 0.

---

## Cross-reference vs Frenly

Frenly schema reviewed for this section: `20260716084652_frenly_v2_saas.sql` (sales
table, `points_ledger`, `retention_programs`/`reward_grants`, `app.on_sale_recorded()`
trigger) and `20260716_frenly_v8_requests_consumption.sql` (`service_products`
bill-of-materials, `app.on_appointment_completed()` FEFO deduction, `change_requests`
+ auto-approve). Only these two migrations were read for this section, per the task
brief; anything attributed to "not seen" below may exist in v3–v7 (points expiry,
referrals, memberships, gift cards, appointments/waitlist/inventory parity) which
were not re-read here.

| # | Flowesce relationship confirmed live | Frenly status |
|---|---|---|
| 1 | Branch existence gates Cash Drawer page | ❌ **Gap.** Neither migration reviewed defines a branch entity distinct from `businesses`, nor any cash-drawer/expected-vs-actual table. Frenly's `businesses` row appears to *be* the single location; no analog for Flowesce's explicit "no branch → no drawer" block was found. |
| 2 | Service→product BOM, qty-per-appointment, configured per service | ✅ **Exact match** — `service_products(service_id, product_id, qty)`, identical shape to what we configured in Flowesce's Service→Inventory tab. |
| 3 | Completion deducts linked stock, FEFO (soonest-expiry batch drained first) | ✅ **Exact match, and more explicit** — `app.on_appointment_completed()` loops `stock_batches` `order by expires_on nulls last, received_on, id`, deducting qty and clamping at zero (never raises on under-stock). Flowesce's behavior looked identical (1 unit deducted, no error path exercised in this pass since stock was sufficient). |
| 4 | Completion creates a sale record | ✅ **Match, but more atomic** — Frenly's same trigger function inserts into `sales` (kind='service') **in the same transaction** as the FEFO deduction, both firing off one status-column UPDATE. Flowesce, by contrast, decouples this: completion alone deducts stock but does **not** create a transaction/sale — that only happens on a separate Checkout/payment action (see step 7b/7c above). **This is a real architectural difference**, not just a gap: Frenly recognizes the sale at completion time regardless of payment status; Flowesce recognizes it at payment time. Neither Frenly migration reviewed models a "completed but unpaid, balance pending" state the way Flowesce's Checkout flow does — partial/deferred payment collection is a **❌ gap** for Frenly if that workflow is ever needed (consistent with `CLAUDE.md`'s note that Stripe SG auto-charge is deliberately deferred). |
| 5 | Sale → points-earn → retention-reward chain | ✅ **Match** — `trg_sale_recorded` → `app.on_sale_recorded()` computes points-per-dollar earn and checks every active `retention_programs` row for a goal-visits-in-period hit, inserting `reward_grants` (+ `credit_ledger` if reward_type='credit'), idempotent via a unique index on `sale_id` (points) and `(program_id, client_id, period_index)` (rewards). This is the "sale→points→retention" chain called out in the brief, and it is real and already built. |
| 6 | Direct retail Quick Sale did **not** update the client's lifetime "Total spent" (step 8 gap) | ✅ **Likely already correct in Frenly, by construction** — Frenly's `sales` table has one shared `kind` enum (`service / retail / membership / quick_sale`) and `on_sale_recorded()` fires generically on **any** insert into that table, not just service-kind ones. If a client-facing "lifetime spend" figure is computed as a sum over `sales` (rather than a narrower appointment-only join, which is what Flowesce's client page appears to do), Frenly would not reproduce this specific gap. **Caveat: not verified against actual UI code** — this is an architectural inference from the schema, not a live-tested confirmation, since Frenly's own app wasn't touched in this task per the scope boundary. |
| 7 | Gift card sold — recorded as a transaction/ledger entry but excluded from revenue until redeemed; cash drawer still credited immediately | ✅ **FIXED in v9** (`frenly_v9_giftcard_revenue`, applied + deployed 2026-07-17) — see the "v9 resolution" section below. Original finding preserved for the record: ❌ **Confirmed real bug, not just a gap** (verified live against Supabase project `kyzovonwnscrzmkvocid`, function `issue_gift_card`, 2026-07-17). On issuance it inserts into `gift_cards` **and also** inserts a row into `sales` with `kind='retail'`, `amount_cents = <card face value>`. Two consequences, neither matching Flowesce: (1) that `sales` row is indistinguishable from a real retail sale, so it will be swept into whatever "Revenue" aggregate sums the `sales` table — i.e. **buying a $25 gift card would inflate reported revenue by $25 at the moment of purchase**, not at redemption, the opposite of the behavior we just confirmed live in Flowesce ("not revenue... until it's redeemed"). (2) `on_sale_recorded()` fires on **every** `sales` insert with no `kind` filter — so that same row would **incorrectly earn loyalty points and count as a qualifying visit toward retention-program goals** for the purchaser, just from buying a gift card, not from an actual visit. Proposed fix (not applied — needs owner approval per `CLAUDE.md`'s production-write rule): give `sales` a `counts_as_revenue`/`counts_as_visit` flag (or a dedicated `kind='gift_card'` that both the revenue rollup and `on_sale_recorded()` explicitly exclude), then have `redeem_gift_card` insert the real revenue-recognized `sales` row at redemption time instead. Separately, `redeem_gift_card` converts remaining balance into `credit_ledger` (`entry_type='gift_card_load'`) — that part **does** match `CLAUDE.md`'s stated single-ledger architecture and is not a bug. |
| 8 | Deposit field, staff assignment, and per-service/per-staff commission-rate fields all live on the Service/Staff forms | ❌ **Confirmed gap, deliberate** — matches `PAGE_INVENTORY.md`'s prior finding ("Frenly: no deposit, no staff assignment"); commission/payroll is explicitly listed in `CLAUDE.md` as "out of scope per owner," so this is a scoped-out exclusion rather than an oversight. |
| 9 | Client-initiated cancel/reschedule request with an auto-approve toggle (the "Requests" module) | ✅ **This exact gap has already been closed, as of `v8`** — `PAGE_INVENTORY.md`'s second pass flagged this as "❌ different: Frenly Bookings = new-booking requests only; no cancel/reschedule flow" and it was the #1 recommended next build slice. The `v8` migration (`change_requests` table + `auto_approve_changes` flag + `request_change`/`decide_change`/`list_my_appointments` RPCs, phone-authenticated) is a close structural match to what we now confirmed live in Flowesce's Requests page (client-initiated CANCEL + RESCHEDULE, approval, auto-approve toggle). Worth updating `PAGE_INVENTORY.md`'s gap table to reflect this is done — flagged here rather than edited there, since editing existing docs was outside this task's instructions. |
| 10 | Appointment "Activity" log only shows creation, never intermediate status changes, despite each producing a distinct user action | ⚠️ **Inconclusive** — `CLAUDE.md` mentions a generic `audit_log` table added in v3, which *could* capture appointment status transitions if those updates are audited generically, but this wasn't verified against the v3 migration (out of scope of the two files read) or against Frenly's UI (no audit-trail view was inspected). Not claiming this as either a match or a gap. |
| 11 | Loyalty/Retention plan-gated on Solo tier regardless of data volume | N/A for Frenly — Frenly has no plan-tier gating concept in the schema reviewed; retention/points are simply enabled per business via `enabled_modules`. Not a gap, just a different monetization model (not gated by plan tier at the data layer in what we reviewed). |

---

## v9 resolution — gift card revenue bug (fixed same day)

Finding #7 above was fixed and shipped on 2026-07-17. Migration
`frenly_v9_giftcard_revenue` (file: `db/migrations/20260717_frenly_v9_giftcard_revenue.sql`),
UI changes in `app/index.html`, deployed to https://frenly-app.vercel.app.

**What changed:** new `sales.kind = 'gift_card'`; `issue_gift_card` writes that kind instead
of `'retail'`; `app.on_sale_recorded()` treats `'gift_card'` exactly as it already treated
`'membership'` (early-return guard + retention visit-count exclusion). `redeem_gift_card`
untouched — deliberately. **Correction to this document's own earlier proposal:** the
original text above suggested moving revenue recognition *into* `redeem_gift_card` via a
sales insert. That was wrong and was not implemented. Redemption loads `credit_ledger`; the
revenue is the real `kind='service'`/`'retail'` sale recorded when the customer actually
spends that credit. A sales insert at redemption would have double-counted.

**Verification — 16-assertion rolled-back chain test, run before applying.** Every assertion
matched its expected value exactly:

| Scenario | Assertion | Expected | Got |
|---|---|---|---|
| A | `sales.kind` of the gift card row | `gift_card` | `gift_card` |
| A | points_ledger rows for purchaser | 0 | 0 |
| A | points_batches rows for purchaser | 0 | 0 |
| A | reward_grants after gift card only | 0 | 0 |
| B | grants after 1 real sale + 1 gift card (goal = 2 visits) | 0 | 0 |
| B | points for C after 1 × $50 service sale | 50 | 50 |
| B | grants after 2 **real** sales | 1 | 1 |
| B | retention credit paid | 1000 | 1000 |
| C | points after a membership sale (v5 regression guard) | 0 | 0 |
| D | new sales rows created by `redeem_gift_card` | 0 | 0 |
| D | credit loaded to recipient by redemption | 2500 | 2500 |
| D | points for recipient after spending the credit | 25 | 25 |
| D | revenue **incl.** gift_card (the old buggy number) | — | 24900 |
| D | revenue **excl.** gift_card (the correct number) | — | 22400 |
| E | bogus kind `'giftcard'` | rejected | rejected |
| E | legacy kind `'quick_sale'` | accepted | accepted |

The D-scenario pair is the money shot: **$249.00 vs $224.00 — a $25.00 overstatement,
exactly the gift card's face value.** And the same $25 previously earned points twice
(25 to the purchaser at purchase + 25 to the recipient at spend); now it earns 25, once.

**Post-apply live verification:** `sales_kind_check` now reads
`kind = ANY (ARRAY['service','retail','membership','quick_sale','gift_card'])`;
`issue_gift_card` contains `'gift_card'`; `on_sale_recorded` contains both
`in ('membership','gift_card')` and `not in ('membership','gift_card')`;
`redeem_gift_card` contains no `into sales`. `public.sales` row count: 0 (pre-launch, so
no backfill was needed and none was done).

### Still open — `sell_package` has the same accounting shape (owner decision needed)

Found while auditing every `sales.kind` writer for v9. `public.sell_package` inserts
`kind='retail'` for a prepaid package. A package is the same shape as a gift card — cash
collected against a liability of unused sessions — so today it books revenue upfront, earns
the buyer points on the full package price, **and counts as a retention visit at purchase**.
Then `use_package_session` inserts a $0 `kind='service'` sale per session, so **a 10-session
package registers 11 visits.**

Deliberately not changed. Revenue-upfront looks intentional (`app/index.html` copy says
"revenue upfront"; the sale toast says "Package sold — revenue booked"), but it is now
asymmetric with the gift-card decision, and the purchase-time retention visit looks
unintentional regardless of how the revenue question is settled. Candidate for v10.

### Also noted, no action taken
- `app.on_sale_stock_deduct()` (the other AFTER INSERT trigger on `sales`) gates on
  `product_id is not null`, not on kind. Gift card sales carry a null `product_id`, so it
  never fired for them and still doesn't. No change needed.
- Frenly's dashboard "Visits (sales)" KPI counts `membership` sales as visits, even though
  the DB retention trigger has excluded membership from visit-counting since v5. Pre-existing
  minor inconsistency, out of v9's scope, left alone.
- `clientDetail()`'s "Visits on record" KPI counts off a `.limit(10)` query and has the same
  conceptual issue, but the fix conflicts with that same array feeding the ledger table
  below it. Genuinely ambiguous; left alone rather than guessed at.

---

**Net takeaway:** the single biggest structural difference confirmed this pass is
**timing of sale-recognition relative to payment**. Frenly's `on_appointment_completed()`
creates the `sales` row (and therefore fires points/retention) the instant status
flips to `completed`, with no independent "payment collected" gate. Flowesce
deliberately decouples "service delivered" (completion → stock deducted, visit
counted) from "payment collected" (Checkout → transaction created, revenue
recognized, cash drawer credited) as two separate, independently-triggerable events.
If Frenly ever needs to support "mark done, collect payment later" (a common salon/
café pattern — tabs, invoicing, walk-out balances), that's a real gap opened up by
this finding, not just a missing feature.
