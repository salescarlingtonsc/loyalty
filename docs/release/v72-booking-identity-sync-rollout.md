# v72 booking identity synchronization rollout

This change must be released database-first.

Predeploy gate: read the production site's actual Supabase publishable key and
confirm it byte-for-byte matches one of `SUPABASE_ANON_KEY`,
`SUPABASE_PUBLISHABLE_KEY`, or `PUBLIC_GATEWAY_PUBLISHABLE_KEY` in the
`public-booking` Edge runtime. Stop the release if no exact match exists; the SDK
would otherwise present that credential as an unknown bearer and receive 401.

1. Apply the v72 migration. It adds the identity-aware 14-argument
   `internal_public_booking_submit` overload while preserving the existing
   13-argument overload as a guest wrapper.
2. Verify both overloads are executable only by `service_role`.
3. Deploy `public-booking`. The new Edge version calls the 14-argument overload
   after validating an optional user bearer token.
4. Verify guest submissions with no Authorization header, SDK submissions with
   an exact configured publishable/anon key, signed-in submissions, replay and
   conflict behavior, and management-token lookup/change.

If the Edge deployment must be rolled back, the prior Edge version continues to
call the retained 13-argument guest overload. Do not remove that overload until
the rollback window is explicitly closed in a later reviewed migration.

The Edge runtime treats only exact values from `SUPABASE_ANON_KEY`,
`SUPABASE_PUBLISHABLE_KEY`, or `PUBLIC_GATEWAY_PUBLISHABLE_KEY` as guest bearer
credentials. Any other bearer is treated as a user token and is accepted only
after `auth.getUser` validates it; malformed, unknown, or expired credentials
receive the gateway's generic 401 response. Approved-origin CORS permits the
Supabase SDK's `apikey` header.

The browser never sends a customer/client ID. SQL resolves the current verified
merchant link. A checked consent box grants marketing consent only for that
resolved relationship and records the validated Auth user in the consent
ledger; an unchecked box is a no-op.

`customer_get_booking_requests` keeps one-argument calls compatible and adds an
optional JSON keyset cursor. It returns every unconverted active request
(`new`, `pending`, `waitlisted`) and 90 days of unconverted terminal decisions
(`declined`, `expired`, `cancelled`). `new` is displayed as `pending`; terminal
statuses are unchanged. Confirmed and appointment-backed requests remain solely
in the appointments feed. Results are newest-first by immutable
`created_at DESC, request_id DESC`; callers continue while `truncated` is true
using the returned `next_cursor`. Cursors must be passed back unchanged.
