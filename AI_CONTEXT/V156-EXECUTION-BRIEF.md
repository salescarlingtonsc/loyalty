# V156 subscription operations and internal CRM execution brief

## Objective

Extend Peekaa's existing platform CRM and Stripe billing authority into one
internal subscription-operations workflow: billing contacts, quotations,
canonical invoices, verified-payment receipts, private PDFs, auditable delivery,
renewal/payment queues, and linked sales/customer lifecycle views.

## Confirmed current behaviour

- Production `/api/build` reports `5bb409103904823466842ea96fe78f0ccbed63e4`.
- V76/V86 already own prospects, contacts, assignments, activities, tasks,
  stages, Kanban and private prospect files. V156 extends these records.
- V77 Stripe webhooks already verify signatures, retain event IDs and payload
  hashes, order events, project subscription-item periods, and make
  `invoice.paid` the only normalized Stripe paid truth.
- V147 owns append-only platform accounting and immutable financial documents.
  V156 adds subscription-document metadata and quotation support without a
  second ledger or payment obligation.
- `sme-private` is a private bucket with short-lived signed access.
- No transactional document-email provider exists in the repository or active
  function inventory. Delivery must fail closed until protected provider
  configuration is supplied.

## Classification

DEEP: payments, subscription access, financial documents, email, internal PII,
RLS, migrations and webhook automation.

## Likely changes

- One additive V156 source migration and canonical Supabase mirror.
- One authenticated document/PDF/delivery Edge Function and a small verified
  hook in the existing Stripe billing webhook.
- Existing platform-console routes/styles and focused V156 tests.
- Product truth, owner ledger, traceability, fixture, architecture decision and
  operational runbooks.

## Explicitly out of scope

Stripe prices/economics, merchant financials, entitlements, loyalty, credits,
commission, appointments, V147 journal/reversal meaning, existing activation,
historical events/documents, tenant roles and merchant navigation.

## Approach

1. Add a protected seller billing profile seeded only with owner-supplied brand,
   legal name, repository-confirmed UEN, SGD bank and contact facts. Keep the
   registered address, billing email, GST decision and terms unset.
2. Extend existing CRM/business records with isolated billing contacts and
   commercial/subscription operations metadata.
3. Keep V147 as the accounting ledger/document authority and add a separate
   operational subscription-document registry for quotations, branded mirrors,
   receipts and subscription summaries; map one operational invoice and at most
   one receipt to each canonical Stripe invoice.
4. Trigger idempotent document/task/activity preparation only after V77 has
   applied a verified provider event. A browser redirect never marks payment.
5. Store immutable PDF revisions in `sme-private`; issue only short-lived reads.
6. Queue auditable email deliveries and retry safely. Missing provider
   configuration remains visible, never reported delivered.
7. Add CRM pipeline/list and system-derived lifecycle/subscription operations
   views behind V89 platform permissions.

## Acceptance and failure cases

- One Stripe invoice maps to one invoice document; receipt exists only after
  normalized paid truth; duplicate/out-of-order events create no duplicate.
- Quotes never imply payment and self-service paid customers do not receive a
  fabricated quote.
- Missing legal/GST/email settings block finalisation or delivery explicitly.
- Final snapshots and PDF revisions are immutable; void/reissue preserves number.
- Billing recipients are business/prospect scoped; merchant and anonymous access
  are denied by RLS and RPC authorization.
- Renewal/payment tasks deduplicate by subscription, invoice and reminder key and
  resolve on recovery.
- Relevant V154/V155, billing, entitlement, storage and permission tests remain
  green. The baseline V151 `dashboardMobileBranchWrap` assertion is already red
  and remains explicitly outside V156.

## Verification and release

Targeted Node/server tests, transaction-scoped database assertions, two-session idempotency where needed,
seven requested responsive viewports, quality/runtime/build/manifest/canonical
checks, database rehearsal, independent high-risk review, then commit/push.
Production migration `20260804051519_nestly_v156_subscription_operations_crm`
and the reviewed Edge Functions were applied after Sol acceptance. Production
web promotion was intentionally stopped because a concurrent session deployed
V157 commit `65887b0f49c1a457f0ea9d5580b6b949ec3fbd53` after this branch was based;
promoting V156 would overwrite that later lineage. A reviewed integration commit
based on the current production build is required before web promotion. No
uncontrolled live charge is permitted.

## Migration and rollback

Forward additive migration only. No historical row rewrite or destructive
rollback. Before deployment, rehearse from the V155 production chain. If the web
or dispatcher fails, disable V156 navigation/dispatcher while retaining immutable
documents/outbox for forward repair.
