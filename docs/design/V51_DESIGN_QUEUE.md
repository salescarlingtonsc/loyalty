# v51+ design queue — approved gaps discovered during the 2026-07-23 gap-closure wave

Each item below was discovered and specified during implementation of the v50-era wave
(commits `2054796` shell → `2a575ff` cart). None is started; all are deliberately deferred
because they need new DB surface or a deploy (both behind `RELEASE APPROVED`). Ordered by
leverage.

## 1. `sale_items` line-item ledger + `record_cart_sale` (v51 core)

Add `public.sale_items(id, sale_id→sales, business_id, item_type, ref_id, description,
qty, unit_cents, line_cents, product_id, staff_id)` written atomically inside a superseding
`record_cart_sale(p_business, p_phone|p_client, p_branch, p_staff, p_method,
p_idempotency_key, p_lines jsonb)` RPC that:
(a) inserts one parent `sales` row for the total AND the child lines in one transaction
under the existing `financial_operations` idempotency guard;
(b) sets `product_id`+`qty` per retail line so the v6 FEFO stock-deduct trigger finally
fires from checkout — TODAY NO WRITE PATH EVER SETS `sales.product_id`, so retail sales
never deduct inventory from any surface (documented, not a cart regression);
(c) records a `payment` row so reporting reconciles tender against itemized revenue.
The shipped cart UI then swaps N calls + note-summary for one `record_cart_sale` with no
UI redesign.

## 2. Idempotent overloads for `sell_package` / `enroll_membership_v41`

Both lack a server-side idempotency key (client-only double-click guards don't survive a
lost-response retry). Add `p_idempotency_key` overloads deduped via `financial_operations`.
This is the sole reason packages/memberships are excluded from cart mode — the cart's
admission rule is "server-idempotent write paths only." With the overloads they join the
cart with zero UI redesign.

## 3. Anon-safe public availability (unlocks true live-slot booking)

One Turnstile+rate-limited gateway action (extend `public-booking` GET with
`?slug=&service=&date=`, or a new `public-availability` function) backed by a new
SECURITY DEFINER RPC `internal_public_slot_availability(slug, service_id, date)` that
reuses the v47 engine (`app.staff_free_for_appointment_v47`) and returns only
non-identifying open slots. Optionally: an opt-in public staff roster (display name + id)
in `get_business_public`, `p_staff uuid` on `internal_public_booking_submit`, and a `staff`
field in `validBookingPayload` — makes staff choice a first-class booking field instead of
the current notes-field preference. Edge Function work → deploy-gated.

## 4. Per-client credit-ledger + gift-card bounded read RPC

Customer 360's timeline cannot show gift-card events or raw credit-ledger movements:
`staff_list_gift_cards` has no client filter and `credit_ledger` is not browser-readable
(only the `client_credit_balance` aggregate view is). Add a bounded, module-gated
`staff_get_client_credit_history(business, client, limit)` in the v49b style.

## 5. `booking_requests` → customer link

Requests are keyed by free-text name/phone/email pre-conversion, so Customer 360 cannot
show "pending booking request" as a next-best-action rule. Either stamp `client_id` at
request time when the phone matches an existing customer (PDPA: server-side only, never
disclosed to the anon requester — must not become a membership oracle), or add a matched
lookup RPC for staff surfaces.

## 6. Coordinated SGT normalization pass (non-blocking)

Assessed benign during the v50a work (labeling/anchor skews only, no rejections, no
double/missed records — see P0-SGT-TIMEZONE-013 §1a): `received_on` / `occurred_on` /
`starts_on` defaults (`current_date` → SGT date), the v11b recurrence `next_run_on <=
current_date` comparison under the 19:xx UTC cron, v18 age brackets. One reviewed
migration normalizing all of them to `(timezone('Asia/Singapore', now()))::date`.

## 7. Deferred UI work (no DB dependency, next UI wave)

- Waitlist → ranked conversion queue (audit §5).
- Close-day reconciliation flow — only if cash tender remains recorded; depends on the
  owner's decision to surface the existing v11b cash-drawer engine in the UI (currently
  pilot-disabled by design).
- My Frenly consumer wallet visual redesign (audit Phase 3).
- Messaging operations (provider, consent, retries, delivery events) — blocked on the
  owner's provider decision (launch gate P0-NOTIFICATIONS-009).
