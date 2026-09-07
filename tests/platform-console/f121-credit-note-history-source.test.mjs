/* Audit finding F121, second half — nestly_v810.
 *
 * f121-credit-note-cumulative-tax.test.mjs proves the ARITHMETIC: given the already-credited
 * totals, creditNoteCumulativeTaxCents() derives a tax that satisfies
 * platform_issue_credit_note_v147's cumulative check exactly. This file proves where those
 * totals COME FROM, which is the half that was still a guess.
 *
 * The console used to reconstruct them in the browser from the sibling documents loaded in the
 * books view. That list is one PAGE of platform_get_accounting_books_v147 (newest first,
 * p_limit), so an older credit note that fell off the page is absent and the running total
 * starts too low; and a loaded row's `reversed` field is not the writer's rule, which excludes
 * a credit note only when a journal_voucher exists against it. Correct arithmetic over the
 * wrong inputs is still rejected by the server.
 *
 * nestly_v810 adds public.platform_invoice_credit_note_totals_v810(uuid) — the same expression
 * the writer checks against, over every document — and creditNoteHistoryV810() prefers it.
 * Preference has a DIRECTION that matters: the loaded window is the fallback, so a failed read
 * degrades to the previous behaviour rather than blocking a legitimate credit note.
 *
 * This test loads the REAL app/platform-console.js in a vm sandbox and calls the REAL exported
 * function against a stub Supabase client, so it executes the wiring rather than grepping for it.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);

async function loadConsole(){
  const source=await readFile(new URL('app/platform-console.js',root),'utf8');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,console,Number,Math,JSON,String,Array,Promise,Error};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

// A stub of the Supabase client shape rpc() expects: {data,error}.
function stubClient(handler){
  const calls=[];
  return {
    calls,
    async rpc(name,args){
      calls.push({name,args});
      return handler(name,args);
    }
  };
}

const INVOICE={id:'inv-1',subtotal_cents:100000,tax_cents:9000};

// The loaded window: it can only see the SECOND credit note, because the first one fell off the
// page. Its totals are therefore wrong, and deliberately so — this is the state that made the
// server reject a correctly typed credit note.
const LOADED_PAGE=[
  {document_type:'credit_note',original_document:'inv-1',subtotal_cents:1050,tax_cents:95,reversed:false},
  {document_type:'receipt',original_document:'inv-1',subtotal_cents:5000,tax_cents:450,reversed:false}
];

test('the SERVER read is preferred over the loaded page, and its numbers are the ones used',async()=>{
  const Console=await loadConsole();
  const sb=stubClient(()=>({data:{
    invoice_id:'inv-1',invoice_subtotal_cents:100000,invoice_tax_cents:9000,
    credited_subtotal_cents:2100,credited_tax_cents:189,credited_total_cents:2289
  },error:null}));

  const history=await Console.creditNoteHistoryV810(sb,INVOICE,LOADED_PAGE);

  assert.equal(sb.calls.length,1,'the console must actually ask the server');
  assert.equal(sb.calls[0].name,'platform_invoice_credit_note_totals_v810');
  // Compared field-by-field, not with deepEqual: the args object is constructed inside the vm
  // realm, so it is not reference-comparable with a host-realm literal.
  assert.equal(sb.calls[0].args.p_invoice,'inv-1');
  assert.equal(Object.keys(sb.calls[0].args).length,1);
  assert.equal(history.source,'server');
  assert.equal(history.priorCreditedSubtotalCents,2100);
  assert.equal(history.priorCreditedTaxCents,189);
  // The page would have said 1050/95 — proof the two genuinely disagree here, or this test
  // would pass no matter which source won.
  assert.notEqual(history.priorCreditedSubtotalCents,1050);
});

test('a FAILED read falls back to the loaded window rather than blocking the credit note',async()=>{
  const Console=await loadConsole();
  const sb=stubClient(()=>({data:null,error:{message:'network',code:'PGRST000'}}));

  const history=await Console.creditNoteHistoryV810(sb,INVOICE,LOADED_PAGE);

  assert.equal(history.source,'loaded-window');
  assert.equal(history.invoiceSubtotalCents,100000);
  assert.equal(history.invoiceTaxCents,9000);
  assert.equal(history.priorCreditedSubtotalCents,1050);
  assert.equal(history.priorCreditedTaxCents,95);
});

test('a read that answers with something non-numeric is treated as a failure, not as zero',async()=>{
  const Console=await loadConsole();
  for(const payload of [null,'nope',{credited_subtotal_cents:'x',credited_tax_cents:0,invoice_subtotal_cents:1,invoice_tax_cents:0}]){
    const sb=stubClient(()=>({data:payload,error:null}));
    const history=await Console.creditNoteHistoryV810(sb,INVOICE,LOADED_PAGE);
    assert.equal(history.source,'loaded-window',`payload ${JSON.stringify(payload)} must not be trusted`);
    assert.equal(history.priorCreditedSubtotalCents,1050);
  }
});

test('a thrown transport error is caught — the modal must never die on this read',async()=>{
  const Console=await loadConsole();
  const sb={async rpc(){throw new Error('offline');}};
  const history=await Console.creditNoteHistoryV810(sb,INVOICE,LOADED_PAGE);
  assert.equal(history.source,'loaded-window');
});

test('the window fallback follows the same reversed/original-document filter it always did',async()=>{
  const Console=await loadConsole();
  const sb={async rpc(){throw new Error('offline');}};
  const history=await Console.creditNoteHistoryV810(sb,INVOICE,[
    ...LOADED_PAGE,
    {document_type:'credit_note',original_document:'inv-1',subtotal_cents:500,tax_cents:45,reversed:true},
    {document_type:'credit_note',original_document:'inv-OTHER',subtotal_cents:700,tax_cents:63,reversed:false}
  ]);
  assert.equal(history.priorCreditedSubtotalCents,1050,'a reversed credit note and another invoice\'s must both be excluded');
  assert.equal(history.priorCreditedTaxCents,95);
});

test('end to end: the server read plus the arithmetic satisfies the writer\'s cumulative check',async()=>{
  const Console=await loadConsole();
  // The exact F121 shape: $1000.00 at 9% GST, one $10.50 credit note already recorded.
  const invoiceSubtotalCents=100000,invoiceTaxCents=9000,firstSubtotal=1050,firstTax=95;
  const sb=stubClient(()=>({data:{
    invoice_id:'inv-1',invoice_subtotal_cents:invoiceSubtotalCents,invoice_tax_cents:invoiceTaxCents,
    credited_subtotal_cents:firstSubtotal,credited_tax_cents:firstTax,credited_total_cents:firstSubtotal+firstTax
  },error:null}));

  // ...and a browser whose loaded page cannot see that first credit note at all.
  const history=await Console.creditNoteHistoryV810(sb,INVOICE,[]);
  const secondSubtotal=1050;
  const tax=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents:history.invoiceSubtotalCents,invoiceTaxCents:history.invoiceTaxCents,
    priorCreditedSubtotalCents:history.priorCreditedSubtotalCents,
    priorCreditedTaxCents:history.priorCreditedTaxCents,
    subtotalCents:secondSubtotal
  });

  // The server's own comparison, from platform_issue_credit_note_v147.
  const required=Math.round((firstSubtotal+secondSubtotal)*invoiceTaxCents/invoiceSubtotalCents);
  assert.equal(firstTax+tax,required,'the writer\'s cumulative check must be satisfied exactly');

  // POSITIVE CONTROL: the empty loaded page really would have produced a rejected figure, so
  // the assertion above is testing something.
  const fromEmptyPage=Console.creditNoteCumulativeTaxCents({
    invoiceSubtotalCents,invoiceTaxCents,priorCreditedSubtotalCents:0,priorCreditedTaxCents:0,
    subtotalCents:secondSubtotal
  });
  assert.notEqual(firstTax+fromEmptyPage,required,
    'sanity: an unseen prior credit note must actually break the check, or this proves nothing');
});
