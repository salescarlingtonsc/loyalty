# V156 subscription-operations authority decision

V156 does not introduce a second CRM, payment authority or accounting ledger.

- Sales workflow remains in V76/V86 `sme_*` records.
- Stripe subscription and paid truth remains V77 provider projections populated
  only after signature-verified webhook processing.
- Merchant access/entitlements remain existing subscription functions.
- Financial effects and corrections remain V147 append-only journals/documents.
- V156 adds customer billing contacts, operational document metadata/PDF
  revisions, delivery attempts, derived lifecycle snapshots and reminder tasks.
- A manually moved sales stage is never authoritative payment or access evidence.
- Manual bank payments are a distinct two-person verification chain and never
  mutate a Stripe invoice.
- Private documents use `sme-private` with short-lived signed access.
- Email delivery is provider-backed only; queued or failed is never called sent.

This boundary preserves existing pricing, entitlements, commission, tenant and
merchant financial semantics while giving the platform team one linked operating
surface.
