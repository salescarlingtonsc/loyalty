import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root=new URL('../..',import.meta.url).pathname;
const read=path=>readFile(join(root,path),'utf8');
const consoleModule=await import('../../app/platform-console.js');

test('v146 exposes Cash P&L only to Super Admin and nests it under Finance',()=>{
  const superAccess=consoleModule.normalizePlatformAccess({role:'super_admin',module_permissions:{'*':'rw'}});
  const adminAccess=consoleModule.normalizePlatformAccess({role:'admin',module_permissions:{billing:'rw'}});
  assert.ok(consoleModule.visibleRoutes(superAccess).some(route=>route.key==='pnl'));
  assert.ok(!consoleModule.visibleRoutes(adminAccess).some(route=>route.key==='pnl'));
  assert.ok(consoleModule.platformNavigationGroups(consoleModule.visibleRoutes(superAccess))
    .find(group=>group.key==='finance').routes.some(route=>route.key==='pnl'));
});

test('v146 accepts only credential-free HTTPS Stripe document links',()=>{
  assert.equal(consoleModule.safeStripeDocumentUrl('javascript:alert(1)'),null);
  assert.equal(consoleModule.safeStripeDocumentUrl('https://stripe.com.evil.test/invoice'),null);
  assert.equal(consoleModule.safeStripeDocumentUrl('https://user:pass@invoice.stripe.com/i/1'),null);
  assert.equal(consoleModule.safeStripeDocumentUrl('https://invoice.stripe.com/i/1'),'https://invoice.stripe.com/i/1');
  const html=consoleModule.billingDocumentLinks({
    paid_normalized:true,
    hosted_invoice_url:'https://invoice.stripe.com/i/1',
    invoice_pdf_url:'https://pay.stripe.com/invoice/1/pdf'
  });
  assert.match(html,/Invoice PDF/);
  assert.match(html,/Receipt/);
  assert.match(html,/target="_blank" rel="noopener noreferrer"/);
});

test('v146 renders signed expense effects and reversal controls truthfully',()=>{
  const CUI={status:(label)=>label};
  const rows=consoleModule.financeExpenseRows([
    {id:'1',entry_type:'expense',expense_date:'2026-08-03',category:'software',description:'Infrastructure',amount_cents:28000,currency:'SGD',reversed:false},
    {id:'2',entry_type:'reversal',expense_date:'2026-08-03',category:'software',description:'Supplier credit',amount_cents:28000,currency:'SGD',reversed:false}
  ],CUI);
  assert.match(rows[0][3],/−SGD 280\.00/);
  assert.match(rows[0][4],/data-reverse-expense="1"/);
  assert.match(rows[1][3],/\+SGD 280\.00/);
  assert.doesNotMatch(rows[1][4],/data-reverse-expense/);
});

test('v146 prospect create keeps one retry key and does not misreport refresh failure',async()=>{
  const source=await read('app/platform-console.js');
  const modal=source.match(/async function newProspectModal[\s\S]+?\n  function prospectImportModal/)?.[0]||'';
  assert.match(modal,/const createAttemptKey=idempotencyKey\(\)/);
  assert.match(modal,/p_idempotency_key:createAttemptKey/);
  assert.doesNotMatch(modal,/p_idempotency_key:idempotencyKey\(\)/);
  assert.match(modal,/controls\.close\(\);[\s\S]+Prospect \{name\} created[\s\S]+try\{await renderOnboarding/);
  assert.match(modal,/was saved\. Refresh the onboarding list/);
});

test('v146 migration is append-only, idempotent, audited and Super Admin scoped',async()=>{
  const sql=await read('db/migrations/20260803_nestly_v146_platform_finance.sql');
  assert.match(sql,/create table public\.platform_operating_expense_entries_v146/i);
  assert.match(sql,/^begin;/m);assert.match(sql,/^commit;/m);
  assert.match(sql,/before update or delete on public\.platform_operating_expense_entries_v146/i);
  assert.match(sql,/unique\(recorded_by,idempotency_key\)/i);
  assert.match(sql,/pg_advisory_xact_lock\(hashtextextended/);
  assert.match(sql,/app\.is_super_admin\(\)/i);
  assert.match(sql,/PLATFORM_EXPENSE_RECORDED_V146/);
  assert.match(sql,/PLATFORM_EXPENSE_REVERSED_V146/);
  assert.match(sql,/paid_normalized and currency='SGD' and paid_at>=v_start/i);
  assert.match(sql,/at time zone 'Asia\/Singapore'/i);
  assert.match(sql,/currency='SGD'/i);
  assert.match(sql,/'adjustments',coalesce/i);
  assert.match(sql,/adjustment_type in \('refund','chargeback','external_payment'\)/);
  assert.match(sql,/original\.adjustment_type in \('refund','chargeback','external_payment'\)/);
  assert.match(sql,/end cash_effect_cents/);
  assert.match(sql,/billing_adjustments_cents/);
  assert.match(sql,/net_cash_cents/);
});

test('v146 rollback evidence covers documents, replay, P&L, denial and immutability',async()=>{
  const sql=await read('db/tests/v146_platform_finance.sql');
  for(const evidence of [
    'Stripe invoice documents were not projected','expense retry was not idempotent',
    'non-Stripe document URL was accepted','changed expense payload replayed',
    'expense reversal retry was not idempotent','cash P&L did not reconcile',
    'cash and non-cash billing adjustment classification failed',
    'Singapore half-open boundary or SGD isolation failed','251-row finance ledger was silently truncated',
    'non-super-admin read platform finance','non-super-admin wrote platform expense',
    'expense ledger accepted an update'
  ])assert.match(sql,new RegExp(evidence));
  assert.match(sql,/^begin;/m);assert.match(sql,/^rollback;/m);
});
