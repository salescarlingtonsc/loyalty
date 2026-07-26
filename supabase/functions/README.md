# Public gateway deployment

Apply `db/migrations/20260718180602_frenly_v19_public_gateway_security.sql` after v18 reporting
and before v20 financial, then deploy these functions. All three functions use custom public
request handling and are configured with `verify_jwt = false`. A service-role-only RPC grant only
allows the Edge handler to invoke the database function; it is not end-user authentication or
authorization. The public controls are the reviewed Edge handler, exact-origin isolation,
context-bound bot verification, rate limits, strict validation, and, for booking management,
proof of the private capability.

The release sequence is fixed: verify the transferred source schema and migration history through
v17, apply v18 reporting, apply v19 public gateway, then apply v20 financial. Do not run a second
migration stream from `supabase/migrations`.

Required secrets:

- `PUBLIC_GATEWAY_ALLOWED_ORIGINS`: comma-separated exact origins, for example
  `https://nestly.asia,https://www.nestly.asia`. Keep preview or legacy origins
  only when they are deliberately supported and included in release smoke tests.
- `PUBLIC_GATEWAY_IP_PEPPER`: at least 32 random characters. Rotating it resets rate-limit buckets.
- `PUBLIC_GATEWAY_TOKEN_SECRET`: at least 32 random characters. It deterministically derives a
  256-bit booking management capability from the business slug and submission ID, allowing the
  same capability to be returned after a lost HTTP response. Only its SHA-256 hash is stored.
- `TURNSTILE_SITE_KEY` and `TURNSTILE_SECRET_KEY`: both are required before exposing public join
  or booking writes. The site key is returned by the public GET functions and rendered explicitly
  by the public pages; the secret is used only for server-side Siteverify.
- `TURNSTILE_TEST_ALLOWED_ORIGINS`: leave unset in production. For staging with Cloudflare's
  official dummy key pair, set it to the exact staging origins allowed to accept the documented
  dummy response (`action=test`, `hostname=localhost`). A test site key and production secret, or
  the reverse, fails closed.

Supabase supplies `SUPABASE_URL` and either `SUPABASE_SECRET_KEYS` or the legacy
`SUPABASE_SERVICE_ROLE_KEY`. Never place a service key, token secret, Turnstile secret, or IP
pepper in frontend code.

Operational security requirements:

- Public write functions fail closed unless both Turnstile keys are configured. Use Cloudflare's
  documented test keys only for local or staging checks, never production. Production widgets use
  distinct `public_join` and `public_booking` actions; Siteverify must return the expected action and
  a hostname equal to the hostname parsed from the already allowlisted exact request `Origin`.
- Malformed and failed-bot submissions count only against a broad pre-verification abuse ceiling.
  The smaller shared-NAT write quota is consumed only after syntax and Turnstile verification pass.
- A failed or lost submission response resets the widget because Turnstile tokens are single-use;
  the retry receives a fresh challenge token but derives the same booking management capability.
- Booking and booking-change idempotency records include a canonical request fingerprint. An exact
  replay returns the original result; reuse of a submission ID with changed fields returns HTTP 409.
  The browser retains an attempt ID only across response-loss retries of the same intended payload.
- Public cancellation may follow the merchant's auto-approval setting. Public reschedules always
  remain pending for staff review until the canonical availability and conflict engine can approve
  hours, capacity, staff and overlap constraints atomically.
- Rotating `PUBLIC_GATEWAY_TOKEN_SECRET` changes every derived capability. Rotation before all
  booking idempotency and management-token windows expire breaks lost-response recovery for old
  submission IDs and invalidates re-derived tokens. Use a planned multi-key transition if rotation
  is required during that period.
- Supabase Edge Functions sit behind Cloudflare; the gateway keys rate limits on the
  Cloudflare-authoritative `cf-connecting-ip`, which is set to the true connecting client and is
  not client-spoofable. The rightmost `X-Forwarded-For` entry is an internal edge node that
  rotates per request and must not be used. Missing or invalid data falls into the shared
  `unknown` bucket and can be conservatively throttled.
- Exact-origin CORS is browser isolation, not authentication. A non-browser client can spoof an
  `Origin`; public writes remain protected by Turnstile and IP limits, while booking management
  additionally requires possession of the capability token.
- RLS is enabled without end-user policies on every `app` gateway table as defense in depth. The
  explicitly granted service-role RPCs are `SECURITY DEFINER` and operate as their owning database
  role; anonymous and authenticated table/function privileges remain revoked.
- Management capabilities received in a URL fragment are copied into memory and immediately removed
  from the current address. Newly issued capabilities are offered as explicit private links but are
  never installed into browser history.

Deploy with:

```sh
supabase functions deploy public-join --no-verify-jwt
supabase functions deploy public-booking --no-verify-jwt
supabase functions deploy manage-booking --no-verify-jwt
```

Do not deploy the frontend until the migration and all three functions are live and smoke-tested.

## Nestly platform billing functions

The v77 billing pipeline uses three separate functions:

- `stripe-billing-webhook` verifies Stripe events and is the only path that
  turns an `invoice.paid` event into paid subscription truth.
- `stripe-billing-command` executes owner/super-admin checkout, portal and
  cadence commands. A redirect is never treated as payment.
- `stripe-billing-reconcile` is the scheduled independent check. It compares
  Stripe subscription and invoice snapshots against Nestly, records a bounded
  reconciliation run and its mismatches, and never fabricates or repairs paid
  state.

Required billing secrets are `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
`BILLING_RETURN_ORIGIN`, and a random `BILLING_RECONCILIATION_SECRET` of at
least 32 characters. The reconciliation scheduler must send that last value in
`x-nestly-reconciliation-secret`. Configure the schedule only after deploying
the function; recommended frequency is daily during trial and every six hours
once live. Store the value in the scheduler's secret store, never in SQL,
frontend code or repository files.

Deploy the billing functions during the reviewed release sequence:

```sh
supabase functions deploy stripe-billing-webhook --no-verify-jwt
supabase functions deploy stripe-billing-command
supabase functions deploy stripe-billing-reconcile --no-verify-jwt
```

Then register Stripe webhook delivery for the event allowlist documented by
v77, invoke one test-mode reconciliation, and retain its run ID as launch
evidence. A `mismatch` or `failed` result blocks billing launch.

## Nestly private SME documents

The v86 document flow keeps the `sme-private` bucket private. An authorized
platform user first reserves an upload or requests a read through the v86
browser RPC. The browser then invokes `sme-document-signer` to exchange the
one-time request token:

- `{"action":"exchange","request_id":"...","exchange_token":"..."}` returns
  either a signed upload token plus its exact bucket/path, or a five-minute
  private read URL.
- After `uploadToSignedUrl` succeeds, `{"action":"finalize","request_id":"..."}`
  makes the trusted function re-resolve the actor-bound target, download the
  stored object, enforce the reserved size, calculate SHA-256 itself, and
  finalize the database record.

The browser never supplies a checksum, observed size, bucket or path to the
finalize action. The one-time database request expires after ten minutes for
uploads and five minutes for reads. Supabase signed upload tokens have their
own platform validity window, so the UI must upload and finalize before the
shorter database reservation expires; a failed/expired reservation is never
reported as uploaded.

Deploy only after v86 has passed independent review:

```sh
supabase functions deploy sme-document-signer
```

`PUBLIC_GATEWAY_ALLOWED_ORIGINS` must include the exact Nestly web origin.
Retain a private-bucket upload/read/finalize acceptance run as launch evidence.
