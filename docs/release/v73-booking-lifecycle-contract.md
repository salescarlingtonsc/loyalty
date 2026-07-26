# v73 staff booking lifecycle contract

V73 adds one staff RPC:

`staff_decide_booking_request_v73(business, request, decision, branch?)`

The only decisions are `confirm` and `decline`; SQL `NULL` is explicitly
rejected and cannot fall through to confirmation. Confirm requires
`appointments:rw` and access to the resolved branch. Decline independently
requires `bookings:rw`; a caller does not need both module writes. When branch is
omitted, the RPC chooses the active default branch, then the oldest active branch
as a deterministic fallback.

The result always includes `request_id`, `requested_decision`, `outcome`,
`actual_status`, and `replayed`. Appointment and linked-waitlist identifiers,
branch, times, and status appear only when they exist. No submitted contact,
client ID, notes, staff ID, or management capability is returned.
`requested_decision` belongs to the mandatory response object and is never
removed by optional-field null stripping.

Outcomes are:

- `applied`: this call performed the transition.
- `replayed`: the same terminal decision was already applied.
- `terminal_conflict`: the opposite decision or another terminal state already won.
- `state_conflict`: the request is not in a recognized actionable state.
- `waitlist_conflict`: a waitlisted request lacks exactly one actionable linked row.
- `capacity_conflict`: live locked table capacity is unavailable.
- `scheduling_conflict`: the v47 scheduler could not safely create an appointment.

Confirming creates a real appointment through the v47 smart scheduler with the
stable idempotency key `booking-request:<request UUID>`. It then copies party
size, portal source, and table type, updates the request to `confirmed`, and
marks an actionable linked waitlist row `booked` in the same transaction.
Decline updates the request to `declined` and an actionable linked waitlist row
to `removed`. Standalone walk-in waitlist rows are never targeted.

The locked booking request is natural idempotency. Replays and conflicts do not
write the v73 decision audit. Each applied transition writes one
`BOOKING_REQUEST_DECISION_V73` event.

A `new` or `pending` table request holds capacity only while `expires_at` is
`NULL` or later than the current database time. The availability view and the
locked confirmation recheck use this same rule, so an expired sibling hold
cannot create a false `capacity_conflict`.

For DB-first compatibility, the existing authenticated
`convert_booking_request(uuid)` signature remains. It delegates to v73 confirm
and preserves the legacy appointment-row success response.

Release only after the v73 preflight confirms there are no cross-tenant or
duplicate linked legacy waitlist rows. Apply the database migration before
shipping any staff UI that calls the new RPC.
