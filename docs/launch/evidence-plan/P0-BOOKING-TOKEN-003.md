# P0-BOOKING-TOKEN-003 — Scoped booking-management token

## 1. Classification

**OWNER-ACTION-SCRIPTED.** The token design and revocation of the legacy phone-only path are
engineering-complete locally and the `manage-booking` function is already deployed; a human still has
to exercise it against production with real HTTP calls and capture the result.

**Verified today (read-only):**
- `tests/public-gateway/public-gateway.test.mjs` includes and passes: "migration stores only SHA-256
  token hashes and links conversion," "management capability is deterministic across lost-response
  retries and domain separated," "booking replay returns the same derived raw capability while SQL
  stores only its hash," and "booking changes are idempotent, conflict truthful and never
  auto-reschedule timestamps."
- `tests/security-hardening/v21-security-hardening.test.mjs` includes and passes "internal RPCs are
  service-only and legacy public gateways are revoked."
- Catalog check: the two legacy phone-only surfaces named in `docs/supabase-sync/VERIFICATION_GATE.md`
  (`public.list_my_appointments(p_slug text, p_phone text)` and `public.request_change(...)`) were **not
  found** in the current `anon`/`PUBLIC` executable function inventory pulled from
  `gadpooereceldfpfxsod` — only `public.get_customer_phone_otp_capabilities()` is anon-executable
  today, and it takes no phone argument. This is consistent with those grants having been revoked, but
  it is a catalog snapshot, not a runtime negative test.
- `app.booking_management_tokens` (RLS enabled, zero policies, zero anon/authenticated table grants)
  confirms the token table itself is unreachable except through `SECURITY DEFINER` RPCs.

## 2. Preconditions

- None owner-decision-wise.
- Ability to issue a real booking through the deployed public gateway to obtain a live token, then use
  it (and deliberately mis-use it) against `manage-booking`.

## 3. Procedure

1. Re-run locally: `node --test tests/public-gateway/public-gateway.test.mjs`.
2. Catalog re-check (read-only, via the Supabase MCP for `gadpooereceldfpfxsod`):
   ```sql
   select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where has_function_privilege('anon', p.oid, 'EXECUTE')
     and n.nspname = 'public';
   ```
   Confirm `list_my_appointments` and `request_change` (phone-arg overloads) are absent.
3. Positive path: create one synthetic booking through `public-booking`, capture the returned opaque
   token, and successfully list/modify that one booking through `manage-booking`.
4. Negative matrix, each against production with synthetic data:
   - Missing token → rejected.
   - Expired token (wait past TTL or use a pre-expired fixture token if the harness supports it) → rejected.
   - Replayed token after its single-use action completed → rejected.
   - Token from booking A used against booking B (cross-booking) → rejected.
   - Phone number alone, no token → rejected (proves the phone-only path is gone end-to-end, not just
     absent from the grant catalog).
5. Confirm only a hash of the token is ever visible in `app.booking_management_tokens` (read-only
   catalog/column check, not a raw value dump) and that `get_logs` for the drill window contains no
   raw token value.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-BOOKING-TOKEN-003.json`
- Example `checks`: `{"positiveTokenFlowPasses": true, "missingTokenRejected": true,
  "expiredTokenRejected": true, "replayedTokenRejected": true, "crossBookingTokenRejected": true,
  "phoneOnlyRejected": true, "legacyGrantsAbsent": true, "onlyHashStored": true}`
- No raw token values, phone numbers, or booking slugs in the summary — counts and pass/fail only.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

45-75 minutes.
