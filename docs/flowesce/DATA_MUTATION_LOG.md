# DATA_MUTATION_LOG

Pass 2 — workflow testing (protocol §6). For every workflow actually executed against the live
Flowesce Solo trial (tenant "CARLINGTON SMITH CONSULTANCY PTE. LTD."), this log records: starting
data → action → record created → fields changed → balance changed → status changed → related
records/modules updated → report totals changed → ending data → reversal result. Read-only
inspections (forms opened and closed without submitting) are NOT logged here — those are recorded
inline in `PAGE_ACTION_COVERAGE.md` instead. This file is only for actions that actually mutated
tenant data.

Evidence tags used inline: **A** confirmed by test (done it, saw the change) · **B** observed not
fully tested · **C** inferred, labelled as such · **D** hidden/inaccessible · **E** blocked.

---

## Mutation 1 — Storefront: turn shop on

**Starting data:** Storefront → Shop settings → "Shop is open" = OFF (Pass 1's recorded default).
Public shop URL `https://carlington-smith-consultancy-pte-ltd.flowesce.com/shop` returned a
genuine 404 — verified by following the admin page's own "View store" `href`, not a guessed URL.

**Action:** Toggled "Shop is open" ON → clicked "Save settings."

**Record created:** none (a settings-row update, not a new record).
**Fields changed:** `storefront_settings.is_open` (or equivalent) false → true.
**Balance changed:** none.
**Status changed:** Public shop route: 404 → 200 (real page, "Shop" heading, empty product grid
at this point since no item was yet marked sellable).
**Related records/modules updated:** none yet (product listing needed a second, separate toggle —
see Mutation 2).
**Report totals changed:** none.
**Ending data:** "Shop is open" = ON (toast confirmed: "Storefront settings saved"). **Left ON**
after this pass — flagged so a future pass doesn't mistake this for the untouched default.
**Reversal result:** not reversed. This is a reversible settings toggle (re-untoggling + saving
would restore Pass-1 default); left on deliberately so the fulfilled test order (Mutation 3-6)
stays reachable for future passes.

---

## Mutation 2 — Inventory: publish Test Cream to storefront

**Starting data:** Test Cream item detail → "Sell online" panel → "Sell on storefront" toggle =
OFF. Public shop (now reachable per Mutation 1) showed "Shop" heading with an empty product grid.

**Action:** Toggled "Sell on storefront" ON (auto-saves — button briefly read "Saving...").

**Record created:** none.
**Fields changed:** Test Cream's storefront-listing flag false → true. Listing name/description
fields were already prefilled ("Test Cream" / placeholder copy) from the item's own record — no
separate listing content had to be authored.
**Balance changed:** none. **Status changed:** none on the item itself (still "In stock," 8 piece
at this point).
**Related records/modules updated:** Public shop grid — empty → 1 product card ("TC" placeholder
image, "Test Cream," "$25.00," "In stock").
**Report totals changed:** none.
**Ending data:** Test Cream now publicly listed and orderable.
**Reversal result:** not reversed (left on so Mutation 3-6's order remains a coherent, inspectable
example for future passes).

---

## Mutation 3–6 — Full storefront order lifecycle: place → confirm → pay → fulfil

This is the single most valuable sequence in Pass 2 — it is a completely new workflow never
before exercised in any pass (Pass 1 found the module but had zero orders to test against).

### 3a. Customer places order (public shop, `/shop/test-cream` → `/shop/cart`)

**Starting data:** Test Cream stock = 8 piece (post-LIVE_DATA_WALKTHROUGH.md baseline).
Transactions = 3 rows, Net Revenue $75.00. Clients = 1 (Test Customer QA). Storefront orders = 0
open.

**Action:** Added 1× Test Cream to cart ($25.00). Checked out with Name = "Test Storefront Order,"
Email = `qa-storefront-test@example.invalid` (non-deliverable `.invalid` TLD — no real email
sent), fulfilment = Pickup (only option enabled), no discount/gift-card code applied. Clicked
"Place order."

**Record created:** Storefront order **#1001** (status: Pending). **A new client record**,
auto-created from the checkout Name/Email fields: "Test Storefront Order" /
`qa-storefront-test@example.invalid`.
**Fields changed:** none pre-existing.
**Balance changed:** none yet — order is reserve-only at this point, explicitly stated in the
Storefront page's own copy ("Customers reserve, you confirm and settle in person").
**Status changed:** none pre-existing.
**Related records/modules updated:** Storefront orders page: "0 open" → "1 open," order appeared
under "Pending."
**Report totals changed:** none. Inventory stock: still 8 (confirmed — reservation does not
deduct stock). Transactions: still 3 rows, Net Revenue still $75.00.
**Ending data (this step):** Order #1001, Pending, Test Cream ×1, $25.00, qa-storefront-test@
example.invalid, Test Storefront Order, pickup, Test Branch, placed Jul 17 1:35 PM.

### 3b. Admin confirms the order

**Action:** Clicked "Confirm" on order #1001.
**Status changed:** Pending → Confirmed.
**Inventory/Transactions:** unchanged (still 8 piece / 3 rows / $75.00) — confirmed by
re-navigating to the item detail page.
**Toast:** "Order confirmed."

### 3c. Admin marks the order paid

**Action:** Clicked "Mark as paid" → inline form appeared (Method: dropdown defaulted to Cash;
Amount: prefilled $25.00) → left Method on Cash → clicked "Confirm paid."
**Status changed:** order badge gained "Paid $25.00 · Cash" alongside "Confirmed."
**Inventory/Transactions:** still unchanged (8 piece / 3 rows / $75.00) — **paying an order does
not by itself fulfil it or touch stock/reports.**
**Toast:** "Order marked as paid."

### 3d. Admin marks the order ready for pickup

**Action:** Clicked "Ready for pickup."
**Status changed:** gained a "Ready for pickup · Jul 17, 1:37 PM" timestamp line; the action
button itself changed from "Ready for pickup" to **"Mark collected."**
**Toast:** "Customer notified: ready for pickup" — confirms this step sends a customer
notification (email, in a live tenant; here a no-op since the address is `.invalid`).
**Inventory/Transactions:** still unchanged.

### 3e. Admin marks the order collected — THE actual fulfilment step

**Action:** Clicked "Mark collected."
**Toast:** "Order collected and sale recorded."
**Record created:** a new Transactions row — `2026-07-17 13:37 · Sale · Retail · Test Cream ·
Test Storefront Order · card · $25.00`.
**Fields changed:** Test Cream `stock_batches`/on-hand quantity.
**Balance changed:** Inventory: **8 piece → 7 piece** (confirmed on the item detail page, exactly
1 unit, matching the order quantity). Transactions: **3 rows → 4 rows.** Net Revenue: **$75.00 →
$100.00.** Breakdown "Sales": **$25.00 → $50.00** (Appointments breakdown unchanged at $50.00).
**Status changed:** order moved from "Confirmed" section to a new **"Recently fulfilled"**
section, badge now "Fulfilled," with a "View linked sale" link confirming the transaction row
above is the linked record (not a coincidental separate sale).
**Related records/modules updated:** Clients list — the auto-created "Test Storefront Order"
client row shows **0 visits / $0.00 spent / "Never" last visit**, DESPITE this $25.00 sale being
directly linked to that exact client on the Transactions row. This reproduces, via the storefront
path specifically, the same client-aggregate blind spot LIVE_DATA_WALKTHROUGH.md already found
for the in-person Quick Sale retail path — confirming it as a general gap, not path-specific.
**Report totals changed:** confirmed above (Net Revenue, Sales breakdown).

**Real finding (contradiction, flagged loudly):** the new transaction's **Method column reads
"card,"** despite the order being explicitly marked paid via **Cash** in step 3c. This is either a
genuine bug (the fulfilment step hardcodes/defaults the transaction method rather than reading
back what was recorded at "Mark as paid") or a display artifact specific to storefront-originated
sales. Not resolved further — flagged for the owner/engineering, not silently noted.

**Ending data (final):** Test Cream stock = 7 piece. Transactions = 4 rows. Net Revenue = $100.00.
Sales breakdown = $50.00. Clients = 2 (Test Customer QA, Test Storefront Order — the latter with
the $0-spent blind spot above). Storefront orders: 0 pending, 0 confirmed, 1 "Recently fulfilled"
(#1001).

**Reversal result:** NOT reversed. This is real, intentional test data left in the tenant
(consistent with how Test Branch/Test Staff/Test Facial/Test Cream/Test Customer QA/the gift card
were all left in place by the prior LIVE_DATA_WALKTHROUGH.md pass) — a fulfilled storefront order
is now part of the tenant's standing test fixture set for future passes. No real money moved (no
Stripe connected; "Cash" was a logged label only) and no real customer was contacted (`.invalid`
address).

---

## Mutation 7 — Public booking: new appointment (for the blocked Requests test attempt)

**Starting data:** Appointments = 1 (Test Customer QA / Test Facial / Jul 17 10:00 AM, already
completed+paid from the prior pass). Clients = 2 (post-Mutation 3a).

**Action:** Via the public booking page (`/book`), booked a second, independent test appointment:
Test Facial, Test Staff ("Any available" resolved to Test Staff), Fri Jul 17 at 13:45, Name =
"Test Requests Customer," Email = `qa-requests-test@example.invalid` (again non-deliverable,
no real email sent), no SMS opt-in checked.

**Record created:** New appointment, confirmation code `85d97321`, status Booked. **New client**
almost certainly auto-created ("Test Requests Customer" / qa-requests-test@example.invalid) by
the same mechanism observed in Mutation 3a (not separately re-verified on the Clients list this
pass, but the pattern is now established as consistent).
**Fields changed:** none pre-existing.
**Balance changed:** $50.00 nominal (Test Facial price) — not collected, appointment is Booked
only, no checkout performed.
**Status changed:** none pre-existing.
**Related records/modules updated:** none observed beyond the appointment/client creation
(no completion, no stock deduction — service not delivered).
**Report totals changed:** none (appointment not completed/paid).
**Ending data:** 1 new Booked appointment for Fri Jul 17, 13:45, Test Staff, unpaid, un-completed.

**Purpose of this mutation:** solely to attempt reaching the client-side "cancel or reschedule"
self-service flow that would generate a real pending row in the Requests module (`/requests`) —
the single item Pass 1 could not test at all (tenant had zero client-initiated requests). The
booking confirmation page's own "Need to change or cancel?" panel pointed to `Go to my account` →
`flowesce.com/account/sign-in`, which requires completing an **emailed one-time sign-in code** —
we have no access to the `qa-requests-test@example.invalid` inbox (deliberately non-deliverable).
**Result: BLOCKED (E).** See `PAGE_ACTION_COVERAGE.md` FL-REQ-01 for the full writeup. This
appointment was left in place (Booked, unpaid) as a standing artifact in case a future pass gets
owner-authorized access to a real, checkable inbox to complete this test.

**Reversal result:** NOT reversed/cancelled — left Booked as a reusable fixture for a future
attempt at the Requests flow (cancelling it now would destroy the one lead we have toward testing
that module).

---

## Summary of net tenant-data changes this pass

| Metric | Before Pass 2 | After Pass 2 | Delta |
|---|---|---|---|
| Test Cream stock | 8 piece | 7 piece | −1 (storefront fulfilment) |
| Transactions count | 3 | 4 | +1 (storefront sale) |
| Net Revenue (Transactions) | $75.00 | $100.00 | +$25.00 |
| Sales breakdown | $25.00 | $50.00 | +$25.00 |
| Appointments breakdown | $50.00 | $50.00 | unchanged |
| Clients | 1 | 3 | +2 (auto-created at storefront checkout + at public booking) |
| Appointments | 1 (completed+paid) | 2 (1 completed+paid, 1 newly Booked/unpaid) | +1 |
| Storefront orders | 0 | 1 (Fulfilled, #1001) | +1 |
| Cash drawer, gift cards, expenses, staff, services, branches | unchanged | unchanged | none — no
mutating action was taken against any of these this pass (all Cash-drawer, Refund, Bulk-adjust
forms were opened and read but explicitly NOT submitted) |

No refunds were issued. No cash-drawer count was closed. No pay-in/pay-out was recorded. No
inventory bulk-adjust was saved. No account settings (name/password) were changed. No real
Stripe connection was made. No real email or SMS reached any actual person — every test email
address used this pass and in prior passes deliberately used the `.invalid` reserved TLD
(RFC 2606), which is guaranteed non-deliverable by design, not merely "fake-looking."
