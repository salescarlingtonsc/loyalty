# P0-PAYMENTS-SUBSCRIPTIONS-010 — Payment collection and SaaS subscription truthfulness

## 1. Classification

**OWNER-DECISION** first (manual invoicing vs. an integrated payment processor — `CLAUDE.md` already
records Stripe SG auto-charge as deferred), then **OWNER-ACTION-SCRIPTED**.

**Verified today — a concrete, load-bearing finding:** production (`gadpooereceldfpfxsod`) is missing
migration `20260722134000_frenly_v49_billing_projection_rpc` (confirmed via read-only
`list_migrations` — see `P0-CUTOVER-PARITY-001.md` for the full pending-migration list). Per
`docs/launch/PRODUCTION_READINESS_REVIEW_2026-07-22.md`, the live Settings/Billing failure
(`public.v_business_billing` calls `app.billable_seats(uuid)`, which `authenticated` cannot execute) is
exactly what v49's "tenant-authorized public RPC" is supposed to fix. **That fix is not yet live in
production.** Any billing-related evidence capture for this gate should first confirm v49 has been
applied (this is the same migration-apply action tracked under `P0-CUTOVER-PARITY-001`) — do not
attempt to evidence a Billing UI fix that database state does not yet support.

## 2. Preconditions

- **OWNER-DECISION:** manual invoicing, or an integrated processor, for both (a) SaaS subscription
  billing (the seat-billing model described in `CLAUDE.md`'s v14 section) and (b) any in-product
  customer-facing payment collection (storefront/checkout). `CLAUDE.md` states plainly: "No Stripe, no
  hard seat cap (blocking invites with no way to pay would brick the pilot)" — i.e. today's answer is
  manual, but that needs a fresh explicit sign-off for the launch record, not an inherited note.
- v49 (`frenly_v49_billing_projection_rpc`) applied to production — shared precondition with
  `P0-CUTOVER-PARITY-001`.

## 3. Procedure

1. Confirm v49 is applied: read-only `list_migrations` on `gadpooereceldfpfxsod`, expect
   `frenly_v49_billing_projection_rpc` present.
2. Owner states the operating model in writing (manual or integrated) for both subscription billing and
   in-product payment collection.
3. **If manual (current default):** document the responsible operator, the invoice-issuance process,
   and what happens to a firm's access if an invoice goes unpaid (the access-control consequence named
   in the gate's own success criteria) — then browser-test that the Billing page in Settings now loads
   for an owner without the `permission denied for function billable_seats` failure, using the
   post-v49 RPC path.
4. **If an integrated processor is introduced instead:** test webhook signature verification,
   idempotency of webhook processing, reconciliation against `v_business_billing`, cancellation, and
   failed-payment handling end to end with a provider sandbox/test mode — none of this exists in the
   repo today, so this path is materially larger scope than the manual path.
5. Either way, audit every place in the UI/marketing copy that claims automated payment, subscription
   renewal, refund, tax handling, or invoicing, and confirm each claim matches the chosen model exactly
   — remove or correct any claim that doesn't.
6. Reconcile one synthetic commercial lifecycle end to end (seat added → billed or invoiced → seat
   removed → billing reflects it) against `v_business_billing`.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-PAYMENTS-SUBSCRIPTIONS-010.json`
- Example `checks` (manual path): `{"v49Applied": true, "operatingModelDocumented": true,
  "billingPageLoadsPostV49": true, "uiClaimsMatchManualModel": true,
  "syntheticLifecycleReconciles": true}`
- Example `checks` (integrated path, additive): add `"webhookSignatureVerified": true,
  "webhookIdempotent": true, "reconciliationClean": true, "cancellationTested": true,
  "failedPaymentHandled": true`.
- No real card numbers, processor secrets, or invoice recipient details in the artifact — this agent
  and the release owner alike must never place payment credentials anywhere; that is also covered by
  this task's own prohibited-action rules.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

- Owner decision: 15-30 minutes if reconfirming the existing manual-billing default; open-ended if the
  owner decides to introduce a processor now (that would itself be new-scope engineering work, not just
  evidence capture).
- Manual-path evidence capture once v49 is applied: 30-45 minutes.
