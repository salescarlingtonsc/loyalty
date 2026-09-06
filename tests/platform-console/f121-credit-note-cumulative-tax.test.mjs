/* Audit finding F121 — accountingCreditModal computed the tax to send as
 * Math.round(subtotal * invoice.tax_cents / invoice.subtotal_cents), a
 * proportion of THIS credit note's own subtotal against the ORIGINAL invoice
 * totals — while platform_issue_credit_note_v147 requires the CUMULATIVE
 * credited tax (this credit plus every non-reversed credit note already
 * issued against the invoice) to equal
 * round(cumulative_subtotal * invoice.tax_cents / invoice.subtotal_cents).
 * Because round(a)+round(b) does not always equal round(a+b), a second
 * partial credit note computed independently of the first could be off by a
 * cent and get rejected by the server's cumulative check even though the
 * typed amount was perfectly valid.
 *
 * The fix extracts the calculation into creditNoteCumulativeTaxCents(), which
 * derives this call's tax as the remainder needed to reach the exact
 * cumulative figure the server checks — first call or Nth, GST-liable or
 * not. This test loads the REAL platform-console.js in a vm sandbox and
 * calls the REAL exported function, and separately proves algebraically that
 * its output always satisfies the server's own comparison for a range of
 * rounding-sensitive inputs mirroring
 * db/migrations/20260803_nestly_v147_platform_accounting.sql's check.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,console};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

// Mirrors the server's exact comparison from platform_issue_credit_note_v147:
//   v_credited_tax+p_tax_cents = round((v_credited_subtotal+p_subtotal_cents)
//     * invoice.tax_cents / invoice.subtotal_cents)   [only when invoice.tax_cents>0]
function serverAccepts({invoiceSubtotalCents,invoiceTaxCents,priorCreditedSubtotalCents,priorCreditedTaxCents,subtotalCents,taxCents}){
  if(invoiceTaxCents===0)return priorCreditedTaxCents+taxCents===0;
  const required=Math.round((priorCreditedSubtotalCents+subtotalCents)*invoiceTaxCents/invoiceSubtotalCents);
  return priorCreditedTaxCents+taxCents===required;
}

test('a FIRST credit note (no prior credits) reproduces the original single-call proportion',async()=>{
  const Console=await loadConsole();
  const tax=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents:10000,invoiceTaxCents:900,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,subtotalCents:4000
  });
  assert.equal(tax,Math.round(4000*900/10000));
  assert.ok(serverAccepts({invoiceSubtotalCents:10000,invoiceTaxCents:900,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,subtotalCents:4000,taxCents:tax}));
});

test('a SECOND partial credit note satisfies the server\'s cumulative check even where per-call rounding would drift by a cent',async()=>{
  const Console=await loadConsole();
  // invoice: $1000.00 subtotal, $77.77 tax (a rate that produces rounding-sensitive splits)
  const invoiceSubtotalCents=100000,invoiceTaxCents=7777;
  // First credit note: $333.33 subtotal.
  const firstSubtotal=33333;
  const firstTax=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents,invoiceTaxCents,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,subtotalCents:firstSubtotal
  });
  assert.ok(serverAccepts({invoiceSubtotalCents,invoiceTaxCents,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,subtotalCents:firstSubtotal,taxCents:firstTax}));

  // Second credit note against the SAME invoice, now that the first is already recorded: $222.22 subtotal.
  const secondSubtotal=22222;
  const secondTax=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents,invoiceTaxCents,
    priorCreditedSubtotalCents:firstSubtotal,priorCreditedTaxCents:firstTax,
    subtotalCents:secondSubtotal
  });
  assert.ok(serverAccepts({
    invoiceSubtotalCents,invoiceTaxCents,
    priorCreditedSubtotalCents:firstSubtotal,priorCreditedTaxCents:firstTax,
    subtotalCents:secondSubtotal,taxCents:secondTax
  }),'the second credit note must satisfy the server\'s cumulative proportionality check');

  // Prove the BUG this replaces would have failed here: proportioning the second call's own
  // subtotal against the original invoice in isolation (the old, broken formula).
  const brokenSecondTax=Math.round(secondSubtotal*invoiceTaxCents/invoiceSubtotalCents);
  const wouldHaveBeenRejected=!serverAccepts({
    invoiceSubtotalCents,invoiceTaxCents,
    priorCreditedSubtotalCents:firstSubtotal,priorCreditedTaxCents:firstTax,
    subtotalCents:secondSubtotal,taxCents:brokenSecondTax
  });
  assert.ok(wouldHaveBeenRejected,
    'sanity check: the OLD per-call-isolated formula must actually be the one that drifts here, or this test proves nothing');
});

test('an invoice with zero GST never proposes a nonzero tax, regardless of prior credits',async()=>{
  const Console=await loadConsole();
  const tax=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents:5000,invoiceTaxCents:0,priorCreditedSubtotalCents:1000,priorCreditedTaxCents:0,subtotalCents:2000
  });
  assert.equal(tax,0);
});

test('a wide sweep of rounding-sensitive two-credit-note sequences always satisfies the server check',async()=>{
  const Console=await loadConsole();
  const invoiceSubtotalCents=987654,invoiceTaxCents=76912; // an intentionally awkward, non-round rate
  for(let firstSubtotal=1000;firstSubtotal<invoiceSubtotalCents/2;firstSubtotal+=97777){
    const firstTax=Console.creditNoteCumulativeTaxCents({
      invoiceSubtotalCents,invoiceTaxCents,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,subtotalCents:firstSubtotal
    });
    const remaining=invoiceSubtotalCents-firstSubtotal;
    const secondSubtotal=Math.min(remaining,53333);
    if(secondSubtotal<=0)continue;
    const secondTax=Console.creditNoteCumulativeTaxCents({
      invoiceSubtotalCents,invoiceTaxCents,
      priorCreditedSubtotalCents:firstSubtotal,priorCreditedTaxCents:firstTax,subtotalCents:secondSubtotal
    });
    assert.ok(serverAccepts({
      invoiceSubtotalCents,invoiceTaxCents,
      priorCreditedSubtotalCents:firstSubtotal,priorCreditedTaxCents:firstTax,
      subtotalCents:secondSubtotal,taxCents:secondTax
    }),`failed at firstSubtotal=${firstSubtotal}`);
  }
});
