# P0-OBSERVABILITY-012 — Error capture, security monitoring, owner alerting

## 1. Classification

**OWNER-ACTION-SCRIPTED**, with one small **OWNER-DECISION** (who is the named on-call/alert recipient
role).

**Verified today:** `mcp__…5cc852de…__get_logs` works read-only today for `api`, `postgres`, `auth`,
`edge-function`, `storage`, and `realtime` services on `gadpooereceldfpfxsod` — the log *sources* exist
and are reachable; what's missing is alert routing, release-correlation, and a rehearsed drill, none of
which live in this repository (they are Vercel/Supabase project configuration).

## 2. Preconditions

- **OWNER-DECISION:** the named operational role(s) that receive alerts for elevated auth failures,
  public-abuse blocks, failed notifications, job failures, and data errors.
- Vercel project access (for client/deployment error capture and release tagging) and Supabase project
  access (for log retention/alert configuration) for whoever performs this.

## 3. Procedure

1. Configure Vercel error capture and release tagging so a client-side error can be correlated back to
   the `/api/build` commit SHA already exposed by `app/api/build.js` (confirmed present and tested today
   — `tests/…` "build identity endpoint exposes only validated non-secret deployment facts" passes).
2. Configure Supabase log retention and alert routes for the named role(s) above, covering: elevated
   authentication failures, public-abuse-gateway blocks, failed notification deliveries, scheduled-job
   (cron) failures, and database/API error spikes.
3. Run one synthetic error drill per surface (deliberately trigger a client error, an Auth failure
   burst, and one abuse-gateway block) and confirm each reaches the named alert route.
4. Confirm log redaction: pull `get_logs` for each service during the drill and confirm no credential,
   token, booking token, customer contact detail, or raw request body appears — only structured,
   redacted entries.
5. Confirm health checks exist for the deployed app and the public gateway functions, and that a
   deployment failure is itself observable (not silent).

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-OBSERVABILITY-012.json`
- Example `checks`: `{"vercelErrorCaptureConfigured": true, "releaseCorrelationWorks": true,
  "alertRoutesConfigured": true, "syntheticClientErrorAlerted": true,
  "syntheticAuthFailureAlerted": true, "syntheticAbuseBlockAlerted": true,
  "logsFreeOfPiiAndSecrets": true, "healthChecksPresent": true}`
- No alert-recipient contact details (email/phone/Slack webhook URL) in the artifact — a role label
  only; the checker's unsafe-content scan will reject an email, phone number, or URL outright.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

60-90 minutes.
