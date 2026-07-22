# P0-PUBLIC-ABUSE-002 — Public join/booking abuse resistance

## 1. Classification

**OWNER-ACTION-SCRIPTED.** The gateway is engineering-complete and already deployed to production;
what remains is a human firing real anonymous HTTP traffic at it and capturing the result — that step
cannot be simulated or asserted by this agent.

**Verified today (read-only):**
- `mcp__…5cc852de…__list_edge_functions` on `gadpooereceldfpfxsod` shows `public-join`, `public-booking`,
  and `manage-booking` all `status: ACTIVE`, `verify_jwt: false` (as intended for anonymous entry),
  version 3.
- `tests/public-gateway/public-gateway.test.mjs` (26/26) and `tests/security-hardening/v21-security-hardening.test.mjs`
  (9/9) pass locally today and specifically assert: exact-origin CORS + mandatory Turnstile, peppered
  rate-limit hashes with bounded TTL and no raw IP column, IP keyed off the trusted Cloudflare header
  (not spoofable `X-Forwarded-For` — matches the user's memory note on gateway rate-limit keying),
  generic (non-enumerating) errors, and that "internal RPCs are service-role-only and legacy public
  gateways are revoked."
- Catalog check: only **one** `SECURITY DEFINER` function in the exposed `public` schema is executable
  by `anon` — `public.get_customer_phone_otp_capabilities()`, which takes no arguments and returns two
  booleans (`sms`, `whatsapp` capability flags derived from `app.platform_feature_enabled`). It performs
  no reads of customer data and no writes. This is a deliberate public capability-discovery function,
  not a data-exposure risk.

## 2. Preconditions

- None owner-decision-wise; this is a runtime proof, not a business call.
- A way to send anonymous HTTP requests to the deployed public gateway (curl, k6, or similar) from an
  operator workstation, and — for the CAPTCHA-bypass negative test — a Turnstile test/sandbox site key
  if one is not already wired to the deployed functions.
- Read access to Supabase Edge Function logs (`get_logs` service=`edge-function`) to confirm no PII
  appears in logs during the drill.

## 3. Procedure

1. Confirm current deployment state (already done today, re-confirm at execution time):
   `list_edge_functions` for `gadpooereceldfpfxsod`; expect `public-join`, `public-booking`,
   `manage-booking` all `ACTIVE`.
2. Run the local static suite one more time immediately before the production drill, to catch any
   regression introduced since this plan was written:
   ```bash
   node --test tests/public-gateway/public-gateway.test.mjs tests/security-hardening/v21-security-hardening.test.mjs
   ```
3. Anonymous smoke (positive path): submit one valid `public-join` and one valid `public-booking`
   request with synthetic data through the deployed function URLs; confirm success and that a
   duplicate/rapid-repeat submission is throttled or deduplicated, not double-processed.
4. Negative/abuse tests: burst N requests past the configured rate limit from one IP and confirm
   throttling; replay a captured request body and confirm no duplicate customer/booking/consent row is
   created; submit with a forged `X-Forwarded-For` and confirm the rate limit still keys off the real
   client IP (per the Cloudflare-header rule), not the attacker-supplied header.
5. Direct-bypass test: attempt the same writes directly against PostgREST/RPC with the anon key (no
   gateway) and confirm they are rejected — this proves "direct anonymous PostgREST and RPC paths
   cannot bypass gateway validation."
6. Pull `get_logs` (service=`edge-function`) for the drill window and confirm no phone number, email,
   name, or raw request body appears — only structured, redacted log lines.
7. Function-grant inventory: re-run the catalog query used for this plan (`anon`/`PUBLIC` execute
   grants on `public.*` `SECURITY DEFINER` functions) and confirm no new anon-executable function
   appeared since this plan was written.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-PUBLIC-ABUSE-002.json`
- Example `checks` block: `{"originAndTurnstileEnforced": true, "rateLimitKeyedOnTrustedIp": true,
  "duplicateSubmissionRejected": true, "directRpcBypassDenied": true, "logsFreeOfPii": true,
  "anonFunctionGrantInventoryUnchanged": true}`
- `summary` should state pass/fail counts and request counts only (e.g. "40 burst requests, 4 accepted
  before throttle, 0 duplicate customers created") — no phone numbers, emails, or full URLs per the
  checker's unsafe-content scan.
- Hash-pin and register in `launch-blockers.json` per the shared procedure in `INDEX.md`.

## 5. Estimated wall-clock time

45-90 minutes (mostly the anonymous request drill and log review; the static re-run is under a minute).
