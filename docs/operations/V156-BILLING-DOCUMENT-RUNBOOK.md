# V156 billing-document runbook

## Configuration gate

The protected seller profile is versioned. The seed contains only the owner-
provided Peekaa/NESTLY legal name, SGD bank account and Lee Chuan Seng contact,
plus the repository's owner-confirmed legal UEN `202634502E`. Before any final
document can be issued, a super admin must configure registered address,
billing email, GST status and default payment terms.

- `not_registered`: document title is `Invoice`; GST number and GST amount are
  absent.
- `registered`: GST registration number and a positive configured rate are
  mandatory. The rate is frozen in the issued snapshot.
- `unconfigured`: finalisation fails closed.

Every save creates a new immutable profile version. Historical document
snapshots never change.

## Document flow

1. Add a primary billing contact and optional CC/accounts-payable recipients to
   the prospect or business.
2. A quotation is finalised from an opportunity with a server-issued
   `QTN-YYYY-NNNNNN` number. Sending first queues one auditable delivery;
   quotation status changes to Sent only after the email provider accepts it.
3. A verified paid Stripe invoice maps to one branded operational invoice with an
   `INV-YYYY-NNNNNN` number. Stripe invoice ID/number remain separate and the
   snapshot states that it is not a second payment obligation.
4. Only a processed, signature-verified `invoice.paid` event creates the
   `REC-YYYY-NNNNNN` receipt and paid document pack. Browser returns,
   `checkout.session.completed`, open invoices and processing intents do not.
5. A delivery worker generates A4 PDFs, stores revisioned objects under the
   private `sme-private` bucket, and sends one provider-idempotent email.

The initial email provider is Resend and requires protected
`RESEND_API_KEY`, `TRANSACTIONAL_EMAIL_FROM`, and
`SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET` function secrets. With missing
configuration, the outbox records `provider_unconfigured`, creates an internal
task, and never reports delivery.

The five-minute database automation requires private Vault values named
`v156_supabase_url` and `v156_dispatch_secret`; the latter must equal the Edge
Function's `SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET`. It replays blocked Stripe
preparations, reclaims expired delivery leases, runs annual 30/14/7 reminders,
and invokes the dispatcher. Resend API acceptance is recorded as
`provider_accepted`, not falsely as end-recipient delivery.

## Manual bank transfer

Create an internal manual invoice, upload evidence privately, and record the
full payment reference/value date/account last four digits. A different super
admin must verify or reject it. Verification issues a receipt and queues the
document pack; it does not mutate a Stripe invoice. Because no existing
authoritative manual-entitlement policy exists, verification creates an urgent
onboarding review task and does not silently grant access.

## Corrections and recovery

Finalised snapshots, event history, PDF revisions and sequence numbers are
immutable. Never delete or reuse a number. Correct by void/reissue or a forward
fix; accounting credits/refunds remain V147/Stripe authority. If delivery is
down, retain the outbox and use the same resend action—resend creates no new
document number.

## Verification commands

```text
node --test tests/platform-admin/v156-subscription-operations-crm.test.mjs
npm run migration-manifest:check
npm run canonical-migrations:check
npm run build
git diff --check
```

Run `db/tests/v156_subscription_operations_crm.sql` against a disposable
current-schema database. Never use an uncontrolled live Stripe charge.
