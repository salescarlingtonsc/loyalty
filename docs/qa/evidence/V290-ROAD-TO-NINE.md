# V290 — the road from 8 to 9: request withdrawal and the offer deep link (2026-08-12)

Owner: "yes please build the road from 8 to 9 - complete the task 100% and verify if it works."
The two feature gaps named in [V285-DEEP-AUDIT-AND-RATING.md](V285-DEEP-AUDIT-AND-RATING.md)'s
closing addendum.

## 1 · A customer can withdraw a booking request nobody has actioned yet

The last hole in the booking loop: appointments could be changed (v286) and guests could cancel
via the manage link, but a signed-in customer's REQUEST — still sitting new/pending/waitlisted
in the business's inbox — had no customer-side exit.

**Server** (`customer_withdraw_booking_request_v290`, applied to production): resolves ownership
EXACTLY as the reader RPC does — verified customer link on the request's business AND a booking
management token bound to `auth.uid()` — so a customer can withdraw precisely the rows the
Bookings page shows them. Row locked; only un-actioned rows move to `cancelled`; a double-tap
replays as success; a decided/converted request refuses with `already_actioned`; anon has no
EXECUTE.

**Verified rolled back against production** with the request's own customer impersonated via
transaction-local JWT claims: withdraw succeeds and the row really is cancelled; the second tap
replays; a confirmed request refuses; a foreign session gets 42501.

**Client**: a Withdraw button on every active request row in #/customer/bookings — confirm
first, busy while in flight, `already_actioned` explained in words, success repaints from the
server.

## 2 · A shared offer deep-links into the app

`/o/<id>`'s "View this offer" now lands on **`#/offer/<id>`** in the app:

- a **stranger** (signed out) is forwarded — after one anonymous read with the 12 s deadline —
  straight to the business's public page: the same place the old link went, and **never a
  sign-in wall** (the route is dispatched before the signed-out destination guard, by design);
- a **signed-in customer** sees the offer itself: artwork uncropped, the Peekaa × firm pairing,
  validity with **live state** ("Ends today" / "Ends tomorrow" / "N days left" — SGT calendar
  days, so 23:59 tonight is *today*, not "tomorrow" because 24 h have not elapsed), and one CTA
  that knows whether they are linked: their own rewards page when they are, the business's
  public page when they are not;
- a **dead link** says "This offer has ended" and offers Home — a shared link outlives the
  offer it carried.

The surface loaders agree `#/offer/` is a customer route (router prefix list + the index.html
preloader that mirrors it), so the deep link downloads the right chunk first.

## Verification

- v290 rollback suite (production, all assertions passed then rolled back) —
  `db/tests/v290_customer_withdraw_booking_request.sql`.
- `tests/customer-wallet/v290-withdraw-and-offer-landing.test.mjs` — 7 tests: wiring, gating,
  the stranger path's no-sign-in-wall rule, the live-state function executed against fixed
  clocks, loader agreement, and the /o/ handoff.
- Suite 2715/2715. Live end-to-end (post-deploy): the /o/ page's button carries
  `/app#/offer/<id>`, and a signed-out headless Chrome following it ends on the business's
  public page — recorded in the session log.
