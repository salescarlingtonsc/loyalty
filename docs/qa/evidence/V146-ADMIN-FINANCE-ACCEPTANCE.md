# V146 Super Admin prospect and platform-finance acceptance

Date: 2026-08-03 (Asia/Singapore)
Branch/worktree: `codex/v146-admin-finance` in the isolated worktree
`/Users/cs/Downloads/loyalty-main-v146-admin-finance`
Release status: local candidate only; not committed, pushed, deployed, or
production verified.

## Outcome and root cause

- The existing V76 prospect RPC succeeds transactionally in a disposable local
  database and exact-key replay returns the original prospect. The browser was
  still creating a new idempotency key on every submit, so a lost response could
  not be retried safely. V146 keeps one request key for the modal lifetime and
  separates the confirmed save message from list-refresh recovery.
- Existing V77/V124/V125 billing stored economic invoice truth but no Stripe
  invoice document URLs. The platform had Billing and Commission pages but no
  valid `#/platform/pnl` route or Peekaa operating-expense ledger.
- V146 adds a Super Admin-only cash P&L, provider-document projection, and an
  append-only SGD expense/reversal ledger. It does not reuse or mix tenant
  merchant finance records.

## Observable acceptance

- A simulated lost response followed by a second **Create prospect** submit
  sends the same idempotency key both times; the successful attempt closes the
  modal and uses the complete Glow Advisory payload.
- August fixture money is exact: paid cash SGD 1,357.00, cash-affecting adjustments
  SGD -20.00, net expenses SGD 400.00, net cash SGD 937.00, and outstanding
  invoices SGD 149.00.
- Credits, debits, write-offs, and their reversals stay visible with zero cash
  effect. Refunds, chargebacks, external payments, and reversals of those events
  use their signed cash effect.
- Paid Radiant exposes Invoice PDF and Receipt. Open Harbour exposes only its
  invoice. JavaScript, credential-bearing, lookalike-host, and non-Stripe URLs
  fail closed.
- Expenses replay exactly, reject changed-payload reuse, cannot be updated or
  deleted, and are corrected by one auditable reversal. A non-Super Admin can
  neither read platform finance nor post an expense.
- Populated, empty, first-load failure, retry, desktop 1440px, and mobile 390px
  finance states execute the production renderer with no console error or
  horizontal viewport overflow and visible actions at least 44px high.

## Verification performed

- `psql .../v146_admin_finance -v ON_ERROR_STOP=1 -f db/migrations/20260803_nestly_v146_platform_finance.sql` — migration applied to a dedicated clone of the latest local schema.
- `psql .../v146_admin_finance -v ON_ERROR_STOP=1 -f db/tests/v76_sme_crm.sql` — pass/rollback.
- `psql .../v146_admin_finance -v ON_ERROR_STOP=1 -f db/tests/v146_platform_finance.sql` — pass/rollback, including document projection/URL denial, replay/conflict, reversal, P&L, audit, denial and immutability.
- The revised database suite additionally proves exact SGD 135,700 / -2,000 /
  -40,000 / 93,700 totals, SGD 14,900 pending, every adjustment class,
  Singapore midnight boundaries, USD exclusion, and a complete 251-row ledger.
- Two simultaneous authenticated expense calls on the dedicated database
  returned the same entry ID with `replayed:false` and `replayed:true`; the
  ledger contained exactly one row.
- `node --test tests/platform/v146-admin-finance.test.mjs tests/platform/v76-sme-crm.test.mjs` — 20/20 pass.
- `node --test tests/platform/*.test.mjs tests/platform-console/*.test.mjs` — 352/352 pass after updating the frozen localization/navigation inventories and production-component fixture.
- `PLAYWRIGHT_MODULE=... node tests/browser/verify-v146-admin-finance.mjs` — desktop/390px populated, empty, retry, and lost-response prospect journeys pass.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run quality` — pass.
- `npm run migration-manifest:check` and `npm run canonical-migrations:check` — pass.

## Remaining gates

- No production write was used to reproduce the owner's failed prospect. Target
  schema-cache/API and authenticated persistence verification remain after an
  authorized release.
- Current production showed six trial/not-collected subscriptions, all SGD 0,
  and no configured Stripe launch prices. Real invoice/receipt/provider
  reconciliation cannot be production-proven until reviewed Stripe prices and
  payments exist.
- Bank-feed or corporate-card ingestion is not configured. V146 automatically
  calculates money-out after an authorized expense entry; it does not invent an
  external expense provider or claim automatic bank settlement.
- Independent Sol review ultimately **ACCEPTED the local V146 phase** with no
  P0-P3 blockers after corrections to refresh control flow, adjustment
  visibility and cash classification, timezone/currency boundaries,
  completeness, concurrency, transaction atomicity, and governed fixture
  reconciliation. This is not release approval. Owner approval, canonical
  release packaging, migration application, deployment, and production
  verification remain prohibited/outstanding.
