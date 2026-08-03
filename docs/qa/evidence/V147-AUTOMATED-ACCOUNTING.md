# V147 automated accounting and financial-document acceptance

Date: 2026-08-03 (Asia/Singapore)
Branch/worktree: `codex/v146-admin-finance` in the isolated worktree
`/Users/cs/Downloads/loyalty-main-v146-admin-finance`
Classification: DEEP
Release status: local candidate only; not committed, pushed, deployed, or
production verified.

## Scope and current behaviour

- V146 already records Stripe billing truth and reversible Peekaa operating
  expenses. V147 adds an append-only, source-idempotent double-entry accounting
  layer. Provider invoice issue/payment, billing adjustments and evidenced
  expenses post balanced journals automatically. Historical provider billing
  backfill replays retained processed events in deterministic chronological
  order; a latest-state projection is used only for legacy invoices with no
  retained processed event.
- The Super Admin Finance page now exposes accounting policy, cash/accrual
  summary, trial balance, journals, financial documents and accounting-period
  controls. Posted history cannot be edited or deleted; correction uses a linked
  reversal or correction document.
- Effective-dated policy stores reviewed legal identity, GST status, financial
  year end, functional currency and document prefix. Issued snapshots contain
  only the public legal identity needed on a document, not internal evidence,
  actor or idempotency metadata.
- The backend issues sequential immutable invoices, receipts, credit notes,
  debit notes, payment vouchers and journal vouchers. Documents have a SHA-256
  snapshot hash and link to their source/original. The UI prints or saves that
  immutable snapshot as PDF; V147 does not yet store a server-rendered PDF
  binary or transmit an InvoiceNow document.
- Generated invoices require one unique approved non-subscription transaction
  reference. The backend rejects references already used by generated or Stripe
  provider invoices, preventing the same sale from being posted through both
  paths.

## Governed fixture and observable acceptance

`PLAT-BOOKS-FY26` uses Peekaa Synthetic Pte. Ltd. with reviewed non-GST status,
SGD functional currency and 31 December financial-year end. Its August sources are:

- paid provider invoice SGD 1,357.00;
- refund SGD 20.00;
- evidenced supplier expense SGD 400.00 with an automatic payment voucher;
- internal invoice SGD 250.00, debit/reversal SGD 30.00, partial receipt
  SGD 100.00 and credit note SGD 50.00.

The books must reconcile exactly to revenue SGD 1,537.00, expenses SGD 400.00,
profit/assets/equity SGD 1,137.00 and liabilities SGD 0.00. The corrected
internal invoice retains SGD 100.00 outstanding. Replays create no second
economic effect; changed-payload key reuse fails.

GST mode fails closed without reviewed registration identity. It generates a
9% tax invoice, requires a proportional GST credit note, and rejects a
GST-bearing debit note. Cumulative credit-note rounding cannot reverse more GST
than the original invoice. A provider invoice later voided reverses its unpaid
accrual; an uncollectible invoice clears the receivable to bad debt without
automatically claiming GST relief. Partial receipts post as deltas, and a later
paid event restores the applicable bad-debt/void amount before recording cash.
Provider posting identities do not depend on a mutable firm name. Locked dates reject all posting until a separately
audited unlock event. Non-Super Admin access, unbalanced journals and mutation
of posted journals/documents are denied.

## Verification

- Clean disposable database restored from the latest local pre-V146 schema;
  V146 then V147 migrations applied successfully in order.
- Before V147, `db/tests/v147_platform_accounting_backfill_setup.sql` inserted
  a retained finalized → SGD 0.40 partial payment → uncollectible → void → SGD
  1.00 paid event chain whose latest projection alone was paid. After migration,
  `db/tests/v147_platform_accounting_backfill_assert.sql` passed: two payment
  journals retained their exact 2/5 October dates, every terminal/recovery link
  existed, receivable and bad debt were zero, revenue and cash were SGD 1.00.
- `db/tests/v146_platform_finance.sql` and
  `db/tests/v147_platform_accounting.sql` — pass/rollback. V147 covers exact
  reconciliation, source/idempotency replay, supplier voucher generation,
  partial receipt/outstanding balance, linked correction/reversal, GST
  fail-closed cases, period lock/unlock, unbalanced-post denial, immutability,
  audit and non-Super Admin denial.
- `db/tests/v147_platform_accounting_concurrency.sh` ran two simultaneous
  authenticated SGD 200.00 receipt attempts against one SGD
  250.00 invoice serialized on the invoice chain: the first committed with SGD
  50.00 remaining, the second failed with `payment exceeds the invoice balance
  or is invalid`, and exactly one SGD 200.00 receipt existed. The harness held
  the first transaction after acquiring the root-chain lock and observed the
  second PostgreSQL session waiting on a lock before allowing the first commit.
  Posting and
  period-lock events also share one transaction advisory gate so a lock cannot
  race a journal into the same period.
- `node --test tests/platform/*.test.mjs tests/platform-console/*.test.mjs` —
  359/359 pass.
- `PLAYWRIGHT_MODULE=... node
  tests/browser/verify-v146-admin-finance.mjs` — pass for desktop 1440px and
  mobile 390px populated/empty/retry/incomplete states, prospect lost-response
  replay, invoice and supplier-expense payloads, general-ledger/balance-sheet
  visibility, and actual print-window identity, source/original linkage, number
  and immutable hash.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run quality` and
  `npm run build` — pass.
- Migration manifest, canonical plan/order and `git diff --check` — pass.
- Independent Sol review accepted the V147 local phase with no remaining P0–P3
  findings after rerunning the V147 static suite (7/7) and `git diff --check`.
  This is local acceptance only, not production or release approval.

## Statutory boundary and remaining integrations

This phase automates bookkeeping and controlled business-document production;
it does not claim to automate legal accountability or external filing.

- A Singapore company must still appoint a company secretary within six months;
  software cannot replace that statutory office.
- Directors remain responsible for true and fair financial statements and for
  audited financial statements when the company is not exempt.
- ACRA annual return/financial-statement filing, IRAS ECI and Form C-S/C,
  GST F5, InvoiceNow/Peppol transmission, payroll, fixed assets/depreciation,
  inventory/cost of sales where applicable, supplier-document OCR, and live
  bank/card feeds remain separate governed integrations.
- Tax invoices, simplified tax invoices, receipts and credit/debit notes must
  continue to follow the company's actual GST registration and transaction
  facts. Accounting and tax records need retention controls consistent with
  the applicable IRAS period.
- Production provider reconciliation, schema-cache verification, authorized
  migration deployment, monitoring and filing-provider acceptance remain
  outstanding.

Authoritative references checked for this phase:

- ACRA, appointing directors and other key officers:
  https://www.acra.gov.sg/register/business/registering-different-business-structures/local-company/appointing-company-directors-other-key-officers/
- ACRA, directors' financial-reporting duties:
  https://www.acra.gov.sg/manage/companies/legal-requirements-common-offences/preparing-financial-statements/financial-reporting-duties-for-directors/
- ACRA, annual-return requirements:
  https://www.acra.gov.sg/manage/companies/legal-requirements-common-offences/filing-annual-returns-companies/deadline-requirements/
- IRAS, invoices, receipts, credit and debit notes:
  https://www.iras.gov.sg/taxes/goods-services-tax-%28gst%29/basics-of-gst/invoicing-price-display-and-record-keeping/invoicing-customers
- IRAS, GST InvoiceNow requirement:
  https://www.iras.gov.sg/taxes/goods-services-tax-%28gst%29/gst-invoicenow-requirement
- IRAS, corporate-income-tax filing forms:
  https://www.iras.gov.sg/taxes/corporate-income-tax/form-c-s-form-c-s-%28lite%29-form-c-filing/guidance-on-filing-form-c-s-form-c-s-%28lite%29-form-c
- IRAS, record keeping:
  https://www.iras.gov.sg/taxes/individual-income-tax/self-employed-and-partnerships/keeping-proper-records-and-accounts
