# P0-AUTH-EMAIL-008 — Password reset, email confirmation, SMTP, anti-automation

## 1. Classification

**OWNER-ACTION-SCRIPTED**, gated by one **OWNER-DECISION** (SMTP provider selection is explicitly
listed as deferred in `CLAUDE.md`: "Stripe SG auto-charge and WhatsApp/SMS remain deferred").

**Verified today:** `tests/security-hardening/v21-security-hardening.test.mjs` includes and passes
"password recovery is complete and non-enumerating" and "auth and public surfaces link to all policy
pages," and `tests/public-gateway/public-gateway.test.mjs` includes "Turnstile validation binds
production tokes to action and Origin hostname" and "staff auth submit stays disabled until Turnstile
returns a token." These are static/source-contract checks on the client and RPC layer; none of them can
prove the Supabase Auth *project settings* (SMTP provider, leaked-password protection, CAPTCHA wiring at
the Auth-service level, redirect allowlist) are actually configured — those live in the Supabase
Dashboard, not in this repository, and this agent's read-only DB access does not reach Auth project
configuration.

## 2. Preconditions

- **OWNER-DECISION:** which SMTP provider sends production email (currently none is committed anywhere
  in the repo or `CLAUDE.md`). Until chosen, no synthetic mailbox test can run.
- Dashboard access to `gadpooereceldfpfxsod` → Authentication settings, for whichever human performs
  step 1 below (this agent's Supabase MCP tools do not expose Auth provider/SMTP configuration reads or
  writes — only `get_logs(service=auth)` for runtime signal).
- A synthetic test mailbox reachable from the chosen SMTP provider.

## 3. Procedure

1. Owner selects and configures the SMTP provider in the Supabase Dashboard for `gadpooereceldfpfxsod`;
   enable email confirmation, leaked-password protection, the password policy, CAPTCHA/Turnstile at the
   Auth-service level (in addition to the client-side Turnstile already tested), and the exact redirect
   URL allowlist for the production frontend origin.
2. Re-run the static suite: `node --test tests/security-hardening/v21-security-hardening.test.mjs tests/public-gateway/public-gateway.test.mjs`.
3. Synthetic account drills against the deployed production URL: sign-up → confirmation email received
   and link works; sign-in; password-reset request → reset email received, link works, old link
   rejected after use; expired-link rejection; a brute-force attempt against sign-in is rate-limited.
4. Log check: `get_logs(service=auth)` for the drill window — confirm authentication failures are
   observable (rate of 4xx/401) without any credential, token, or password value appearing in the log
   line.
5. Confirm no development sender or test recipient dependency remains (e.g. no hardcoded personal email
   in a "from" or "bcc" address).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-AUTH-EMAIL-008.json`
- Example `checks`: `{"smtpProviderConfigured": true, "emailConfirmationEnabled": true,
  "leakedPasswordProtectionEnabled": true, "captchaEnabled": true, "redirectAllowlistCorrect": true,
  "signupConfirmationDelivered": true, "passwordResetDelivered": true, "expiredLinkRejected": true,
  "bruteForceRateLimited": true, "authLogsFreeOfSecrets": true}`
- Never place the SMTP provider's API key, the synthetic mailbox address, or any reset/confirmation
  link in the artifact — the checker's unsafe-content scan will reject an email address, a full URL, or
  a JWT-shaped token outright. Use "provider configured: yes/no" and counts only.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

- Owner decision (SMTP provider choice): variable, potentially the longest pole in the whole 17-gate
  critical path if no provider is pre-selected.
- Configuration + drills once decided: 60-90 minutes.
