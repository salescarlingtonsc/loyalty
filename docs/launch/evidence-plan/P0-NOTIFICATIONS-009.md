# P0-NOTIFICATIONS-009 — Customer and staff notification behavior

## 1. Classification

**OWNER-DECISION** first, **OWNER-ACTION-SCRIPTED** after.

`CLAUDE.md` records this as an explicit, standing owner deferral: "Stripe SG auto-charge and
WhatsApp/SMS remain deferred, but note this now BLOCKS Transactions / Cash drawer / Deposits / the
checkout split. Email campaigns are a separate capability the comms deferral arguably doesn't cover —
unresolved." That last sentence is itself an unresolved scope question this plan cannot close on the
owner's behalf.

**Verified today:** `public.customer_notification_outbox` and `public.customer_notification_preferences`
exist with RLS enabled and no direct anon/authenticated table grants (RPC-only, per the advisor-triage
catalog check) — the outbox/preference *data model* is built. Nothing in the repo configures an actual
outbound provider (email/SMS/WhatsApp) today; the deferral in `CLAUDE.md` is current and correct.

## 2. Preconditions (OWNER-DECISION)

- Does "email campaigns" fall inside or outside the standing comms deferral? (Named explicitly as
  unresolved in `CLAUDE.md`.)
- Which channel(s) launch with: email only, or email + SMS/WhatsApp?
- Provider selection per channel, and whether a sandbox/test mode exists for that provider.
- For any promise the product currently makes in its UI copy about a notification firing (booking
  confirmation, reminder, staff alert, etc.) that has no configured provider yet: remove the promise
  from the UI, or explicitly accept it as "silently not sent" for launch — do not ship a UI claim with
  no backing mechanism.

## 3. Procedure

1. Owner resolves the scope/provider decisions above.
2. Inventory every UI string that promises a notification (booking confirmation, change confirmation,
   reminder, staff alert, low-stock alert, etc.) and map each to either a configured provider or a
   removed/rewritten UI claim.
3. Configure the chosen provider(s) in a sandbox mode first; wire `customer_notification_outbox` writes
   to actually enqueue and the outbox consumer to actually attempt delivery.
4. Synthetic delivery tests: booking created → confirmation sent; booking changed → change notice sent;
   reminder job fires at the correct SGT-relative time; a forced provider failure is retried per the
   configured policy and does not duplicate the underlying booking/sale/loyalty-credit effect it is
   describing; unsubscribe/opt-out is honored and is independent from transactional (non-marketing)
   messages.
5. Staff-alert path: trigger one staff-facing alert condition (if any ship at launch) and confirm
   delivery and consent/opt-out separation from customer marketing consent.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-NOTIFICATIONS-009.json`
- Example `checks`: `{"scopeDecisionRecorded": true, "everyUiPromiseMapped": true,
  "providerConfiguredSandbox": true, "bookingConfirmationDelivered": true,
  "changeNoticeDelivered": true, "reminderTimingCorrectSgt": true, "failureRetriedNoDuplicateEffect": true,
  "unsubscribeHonored": true, "marketingAndTransactionalConsentSeparate": true}`
- No real phone numbers, email addresses, or message bodies in the artifact — synthetic recipient
  labels and counts only.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

- Owner decision: 30-60 minutes (compounded by the unresolved "does comms deferral cover email
  campaigns" question, which may need its own short discussion).
- Configuration + drills once decided: 2-4 hours, this is one of the larger remaining gates because a
  provider integration does not exist yet.
