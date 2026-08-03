import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

test('v147 accounting is append-only, balanced, source-idempotent and Super Admin only',async()=>{
  const sql=await read('db/migrations/20260803_nestly_v147_platform_accounting.sql');
  assert.match(sql,/^begin;/m);assert.match(sql,/^commit;/m);
  assert.match(sql,/create table public\.platform_accounting_journal_entries_v147/i);
  assert.match(sql,/create table public\.platform_accounting_journal_lines_v147/i);
  assert.match(sql,/unique\(source_type,source_id\)/i);
  assert.match(sql,/v_debits<>v_credits/);
  assert.match(sql,/posted accounting records are immutable; reverse and replace instead/);
  assert.match(sql,/app\.is_super_admin\(\)/);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/platform_accounting_period_gate/);
  assert.match(sql,/platform_accounting_policy_version/);
  assert.match(sql,/platform_document_chain/);
  assert.match(sql,/platform_accounting_date_locked_v147/);
  assert.match(sql,/PLATFORM_JOURNAL_POSTED_V147/);
});

test('v147 automatically posts authoritative billing, adjustment and expense sources',async()=>{
  const sql=await read('db/migrations/20260803_nestly_v147_platform_accounting.sql');
  for(const source of ['platform_provider_invoice_post_v147','platform_billing_adjustment_post_v147','platform_expense_post_v147','provider_invoice_issued','provider_invoice_payment','billing_adjustment','platform_expense'])assert.match(sql,new RegExp(source));
  for(const terminal of ['provider_invoice_void','provider_invoice_uncollectible','provider_invoice_uncollectible_recovery','provider_invoice_void_recovery','provider_invoice_uncollectible_to_void'])assert.match(sql,new RegExp(terminal));
  assert.match(sql,/platform_provider_invoice_state/);
  assert.match(sql,/platform_sync_provider_invoice_event_v147/);
  assert.match(sql,/Replay retained provider events so historical books match the live state machine/);
  assert.match(sql,/from public\.billing_provider_events event where event\.processing_status='processed'/);
  assert.match(sql,/order by event\.object_id,event\.event_created_at,app\.stripe_event_rank_v77\(event\.event_type\),event\.event_id/);
  assert.match(sql,/Projection-only rows are a legacy fallback and are never double-backfilled/);
  for(const adjustment of ['refund','chargeback','external_payment','credit','debit','writeoff','reversal'])assert.match(sql,new RegExp(`'${adjustment}'`));
});

test('v147 migration backfill reconstructs historical partial and terminal provider transitions',async()=>{
  const setup=await read('db/tests/v147_platform_accounting_backfill_setup.sql');
  const assertion=await read('db/tests/v147_platform_accounting_backfill_assert.sql');
  for(const transition of ['invoice.finalized','invoice.payment_failed','invoice.marked_uncollectible','invoice.voided','invoice.paid'])assert.match(setup,new RegExp(transition.replace('.','\\.')));
  for(const evidence of ['historical provider transition chain was not reconstructed','historical provider chain balances do not match live accounting','historical partial and final cash dates were collapsed'])assert.match(assertion,new RegExp(evidence));
  assert.match(assertion,/source_id=v_invoice\|\|':40'.*journal_date='2026-10-02'/s);
  assert.match(assertion,/source_id=v_invoice\|\|':100'.*journal_date='2026-10-05'/s);
  assert.match(assertion,/^rollback;/m);
});

test('v147 controls policy, document numbering, invoices, receipts, credits and reversals',async()=>{
  const sql=await read('db/migrations/20260803_nestly_v147_platform_accounting.sql');
  for(const contract of ['platform_set_accounting_policy_v147','platform_record_operating_expense_v147','platform_create_invoice_v147','platform_record_invoice_receipt_v147','platform_issue_credit_note_v147','platform_issue_debit_note_v147','platform_reverse_financial_document_v147','platform_get_accounting_books_v147'])assert.match(sql,new RegExp(contract));
  assert.match(sql,/document_number text not null unique/);
  assert.match(sql,/snapshot_sha256/);
  assert.match(sql,/invoice tax rate does not match reviewed tax status/);
  assert.match(sql,/debit notes are limited to transactions where no GST is charged/);
  assert.match(sql,/cumulative credit note tax must proportionally reverse/);
  assert.match(sql,/generated_non_subscription_invoice/);
  assert.match(sql,/transaction reference already exists in generated or provider billing/);
  assert.match(sql,/invoice with payments, credits or debits must be corrected through linked documents/);
  assert.match(sql,/row_counts.*journals.*documents/s);
});

test('v147 UI exposes complete books and controlled correction documents inside Super Admin finance',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/platform_get_accounting_books_v147/);
  assert.match(source,/Accounting books/);
  assert.match(source,/Trial balance/);
  assert.match(source,/General ledger/);
  assert.match(source,/Equity & current profit/);
  assert.match(source,/Approved transaction reference/);
  assert.match(source,/Original document/);
  assert.match(source,/GST rate/);
  assert.match(source,/platform_create_invoice_v147/);
  assert.match(source,/platform_record_invoice_receipt_v147/);
  assert.match(source,/platform_issue_credit_note_v147/);
  assert.match(source,/platform_issue_debit_note_v147/);
  assert.match(source,/platform_reverse_financial_document_v147/);
  assert.match(source,/Print \/ save PDF/);
  assert.match(source,/Accounting period locked/);
});

test('v147 rollback evidence covers reconciliation, terminal invoices, cumulative GST, replay, locks, denial and immutability',async()=>{
  const sql=await read('db/tests/v147_platform_accounting.sql');
  for(const evidence of ['accounting policy retry did not replay','supplier expense did not generate a payment voucher','invoice retry was not exact','changed invoice payload replayed','generated invoice accepted a duplicate economic source reference','generated invoice accepted a provider invoice reference','debit note numbering failed','issued document lost its immutable issuer snapshot','partial receipt did not retain exact balance','books do not reconcile','trial balance does not balance','authoritative source posted more than once','void provider invoice left accrual balances posted','uncollectible provider invoice did not clear receivable to bad debt','partial payment then void did not reconcile cash and receivable','uncollectible then void did not reclassify terminal accounting','partial uncollectible then void then paid did not reconcile','uncollectible recovery after business rename did not reconcile','reversed receipt still reduced receivable','GST credit note accepted a non-proportional tax reversal','cumulative GST credits exceeded proportional original tax','GST-bearing debit note was accepted','locked period accepted a posting','unbalanced journal was accepted','posted journal accepted mutation','issued document accepted mutation','non-super-admin read platform books','non-super-admin generated a financial document'])assert.match(sql,new RegExp(evidence));
  assert.match(sql,/^begin;/m);assert.match(sql,/^rollback;/m);
});

test('v147 includes a disposable two-session overpayment regression',async()=>{
  const script=await read('db/tests/v147_platform_accounting_concurrency.sh');
  assert.match(script,/Refusing concurrency writes outside a v147_\*/);
  assert.match(script,/platform_record_invoice_receipt_v147/);
  assert.match(script,/wait_event='PgSleep'/);
  assert.match(script,/wait_event_type='Lock'/);
  assert.match(script,/Second receipt did not block on the held invoice-chain lock/);
  assert.match(script,/Expected one success and one PostgreSQL rejection/);
  assert.match(script,/receipt serialization passed/);
});
