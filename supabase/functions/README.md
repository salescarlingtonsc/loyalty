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

- `PUBLIC_GATEWAY_ALLOWED_ORIGINS`: optional comma/newline-separated exact
  origins (or a JSON string array) for deliberately supported preview/staging
  hosts. The two canonical production origins, `https://peekaa.asia` and
  `https://www.peekaa.asia`, are immutable trusted defaults in the shared
  gateway. Wildcards, credentials, paths, query strings and non-loopback HTTP
  origins are rejected. Keep preview or legacy origins only when they are
  deliberately supported and included in release smoke tests.
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
supabase functions deploy public-business-application --no-verify-jwt
```

The v95 `public-business-application` handler is the only public application-write path. It
requires the distinct `business_application` Turnstile action, applies broad abuse and narrower
write limits, and invokes the service-role-only `internal_submit_business_application_v95`
contract. Browsers cannot invoke that write RPC directly. Its GET status response uses only an
unguessable public reference and returns no applicant PII, decision reason, invitation, or token.

Do not deploy the frontend until the migration and all public functions it calls are live and
smoke-tested.

## Peekaa platform billing functions (Razorpay, nestly_v755)

Platform billing moved from Stripe Subscriptions to **Razorpay Subscriptions**
(nestly_v755, owner decisions 2026-09-04). Stripe Connect / PayNow POS has no
Razorpay SG equivalent and was removed rather than ported — see
`RAZORPAY_SWAP_SPEC.md` in the repo root for the full build spec. The
`stripe-billing-*` and `stripe-connect-*` functions are retired; do not
redeploy them.

The v755 billing pipeline uses four separate functions:

- `razorpay-billing-webhook` verifies the raw body against
  `X-Razorpay-Signature` and is the only path that turns a
  `subscription.charged` event into paid subscription truth. Event dedupe
  keys on `x-razorpay-event-id` (falling back to a sha256 of the body).
- `razorpay-billing-command` executes owner/super-admin checkout, cancel,
  resume and cadence/capacity/branch commands via plain `fetch` + HTTP Basic
  auth against the Razorpay REST API. A redirect is never treated as
  payment. Razorpay has no customer billing portal, so `create_portal` is
  not offered by the client; cancel/resume use the existing
  `cancel_at_period_end` / `resume` command types instead.
- `razorpay-billing-reconcile` is the scheduled independent check. It
  compares Razorpay subscription and payment snapshots against Peekaa and
  records a bounded reconciliation run and its mismatches. Since nestly_v759
  it also RECOVERS: a Razorpay subscription that is paid (`active`, or
  `authenticated` with `paid_count > 0`), belongs to a tenant already in the
  run's Razorpay scope, and has no local mirror is re-read from the REST API,
  its paid invoices and payments fetched, and webhook-shaped envelopes are
  pushed through the existing `ingest_billing_event_v755` ->
  `apply_razorpay_billing_event_v755` pipeline. It still fabricates nothing —
  every field comes from a provider GET and there is no second writer of
  billing truth. Recovery is bounded to 10 subscriptions per run, is
  idempotent (deterministic event ids, so a re-run dedupes in the inbox), and
  its failures are counted in the run summary as `recovered:{attempted,
  succeeded,failed}` rather than failing the run. An abandoned hosted checkout
  (`created`/`expired`, or an authenticated mandate that has never charged) is
  never recovered and keeps its `pending_checkout` classification.
- `razorpay-billing-return` (new in v755) is the `callback_url` target for
  Razorpay Checkout.js's `redirect:true` flow. It verifies
  `razorpay_signature` (HMAC-SHA256 of `payment_id|subscription_id` with the
  key secret) and 303-redirects to the command's existing success/cancel
  URLs. It never writes payment truth itself.

Required billing secrets are `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`,
`RAZORPAY_WEBHOOK_SECRET`, `BILLING_RETURN_ORIGIN`, and a random
`BILLING_RECONCILIATION_SECRET` of at least 32 characters (unchanged from the
Stripe pipeline). The reconciliation scheduler must send that last value in
`x-nestly-reconciliation-secret`. Configure the schedule only after deploying
the function; recommended frequency is daily during trial and every six hours
once live. Store every secret in the scheduler's / Supabase project's secret
store, never in SQL, frontend code or repository files. Key id prefix
`rzp_test_` vs `rzp_live_` determines livemode — there is no separate livemode
flag in the webhook payload. `RAZORPAY_PLAN_MAP_JSON` is an optional
test-mode override mapping a catalogue price-id column to a live Razorpay
`plan_...` id, for use before the catalogue is fully configured with real
plan ids.

### Rotating the webhook secret (nestly_v759)

`RAZORPAY_WEBHOOK_SECRET_PREVIOUS` is an OPTIONAL second webhook secret. The
webhook accepts a body that verifies against **either** secret and logs which
one matched as `secret:"current"` or `secret:"previous"` on the accepted line
(the label only — never a value).

It exists because a rotation is not atomic. Razorpay's own guidance: *"If you
have changed your webhook secret, remember to use the old secret for webhook
signature validation while retrying older requests."* Deliveries already queued
when the dashboard secret changes are still signed with the OLD secret and are
retried for 24h; verifying against the new secret alone answers every one of
them `400`, and 24h of failures makes Razorpay disable the endpoint. That is
exactly the live incident of 2026-09.

Procedure:

1. `supabase secrets set RAZORPAY_WEBHOOK_SECRET_PREVIOUS=<the current secret>`
2. Change the secret in the Razorpay dashboard, then
   `supabase secrets set RAZORPAY_WEBHOOK_SECRET=<the new secret>`
3. Wait at least 24h — Razorpay's full retry window — and watch the accepted
   log lines. Once none of them says `secret:"previous"`, the old secret is no
   longer carrying traffic.
4. `supabase secrets unset RAZORPAY_WEBHOOK_SECRET_PREVIOUS`

Leaving `RAZORPAY_WEBHOOK_SECRET_PREVIOUS` set indefinitely keeps a retired
secret valid, so step 4 is part of the rotation, not optional. Unset or empty
is the steady state, in which only `RAZORPAY_WEBHOOK_SECRET` is accepted.

Deploy the billing functions during the reviewed release sequence:

```sh
supabase functions deploy razorpay-billing-webhook --no-verify-jwt
supabase functions deploy razorpay-billing-command
supabase functions deploy razorpay-billing-reconcile --no-verify-jwt
supabase functions deploy razorpay-billing-return --no-verify-jwt
```

Then, in the Razorpay dashboard, register **test-mode** webhook delivery
first (test and live webhooks are configured separately) and tick every event
this pipeline consumes:

- `subscription.authenticated`
- `subscription.activated`
- `subscription.updated`
- `subscription.resumed`
- `subscription.pending`
- `subscription.halted`
- `subscription.paused`
- `subscription.cancelled`
- `subscription.completed`
- `subscription.charged`
- `refund.created`

Invoke one test-mode reconciliation and retain its run ID as launch evidence.
A `mismatch` or `failed` result blocks billing launch. Only move the webhook
registration to live mode, and swap in `rzp_live_*` secrets, once test-mode
checkout, webhook delivery and reconciliation have all been proven end to
end.

## Peekaa private SME documents

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

`PUBLIC_GATEWAY_ALLOWED_ORIGINS` may add intentional non-production origins;
it cannot remove or broaden the two exact canonical Peekaa origins. Retain a
private-bucket upload/read/finalize acceptance run as launch evidence.
