import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

// A minimal stand-in for CustomerUI. It renders each translated slot between
// angle brackets so an untranslated string is visible to the locale assertions
// below; the real helper is exercised by the admin visual fixture.
const stubCUI=Object.freeze({
  icon:name=>`<i>${name}</i>`,
  card:({title,description,body})=>`<section><h2>${title}</h2><p>${description??''}</p>${body}</section>`,
  table:({caption,headers,rows})=>`<table><caption>${caption}</caption><tr>${
    headers.map(header=>`<th>${header}</th>`).join('')}</tr>${
    rows.map(row=>`<tr>${row.map(cell=>`<td>${cell}</td>`).join('')}</tr>`).join('')}</table>`,
  emptyState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`
});
const localizedCUI=api=>api.localizedPlatformCUI(stubCUI);

// A firm that is late, on manual collection, with one invoice still open and a
// payment claimed but not yet verified — the case the drawer exists for.
const chasedFirm={
  today:'2026-08-08',
  company:{id:'b-1',name:'Loyang Cafe',legal_name:'LOYANG CAFE PTE LTD',
    sector:'cafe',currency:'SGD',branch_count:2,seat_count:3},
  subscription:{status:'active',payment_status:'past_due',billing_provider:'manual',
    collection_mode:'chase',billing_cadence:'monthly',currency:'SGD',
    period_total_cents:9900,current_period_start:'2026-07-04T00:00:00+08:00',
    current_period_end:'2026-08-03T00:00:00+08:00',
    next_payment_at:'2026-08-03T00:00:00+08:00',days_until_due:-5},
  outstanding:{open_invoice_count:1,balance_due_cents:9900,currency:'SGD',
    oldest_due_date:'2026-07-27',days_outstanding:12},
  contacts:[{id:'c-1',full_name:'Tan Wei Ming',title:'Owner',
    email:'wei@example.test',phone:'+65 8000 0001',is_primary:true}],
  consultant:{id:'k-1',display_name:'Priya',active:true},
  payments:[
    {id:'d-1',document_type:'invoice',document_number:'INV-0002',issue_date:'2026-07-13',
     due_date:'2026-07-27',currency:'SGD',total_cents:9900,amount_paid_cents:0,
     balance_due_cents:9900,manual_status:'pending_verification',
     manual_reference:'PAYNOW-8891',manual_bank_last4:'4417'},
    {id:'d-2',document_type:'invoice',document_number:'INV-0001',issue_date:'2026-06-13',
     due_date:'2026-06-27',currency:'SGD',total_cents:9900,amount_paid_cents:9900,
     balance_due_cents:0}
  ],
  payments_truncated:false
};

test('the drawer states the firm’s debt, its collection mode and how late it is',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const html=api.companyDetailHtml(chasedFirm,localizedCUI(api));

  assert.match(html,/SGD 99\.00/,'the outstanding balance must be shown as money');
  assert.match(html,/5 days overdue/,'lateness must be stated, not left to arithmetic');
  assert.match(html,/Chase/,'a manual-billing firm must read as a chase');
  assert.doesNotMatch(html,/Auto-collect/,'a chased firm must not claim to auto-collect');
  // The console never names payment brands; "GIRO" and "PayNow" describe rails,
  // not the work, and the owner asked for the work.
  assert.doesNotMatch(html,/GIRO|Stripe/i,'collection is described as work, not by payment brand');
  assert.match(html,/12/,'days outstanding must be visible');
  assert.match(html,/owes money/i,'an unpaid firm must be called out, not left to the reader');
});

test('a claimed but unverified payment never reads as settled',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  assert.equal(api.companyPaymentProofLabel(chasedFirm.payments[0]),'Awaiting verification');
  assert.equal(api.companyPaymentProofLabel(chasedFirm.payments[1]),'Settled');
  assert.equal(api.companyPaymentProofLabel({balance_due_cents:9900}),'Unpaid');
  assert.equal(api.companyPaymentProofLabel({manual_status:'verified'}),'Proof verified');
  assert.equal(api.companyPaymentProofLabel({manual_status:'rejected'}),'Proof rejected');

  const html=api.companyDetailHtml(chasedFirm,localizedCUI(api));
  const open=html.indexOf('INV-0002');
  assert.ok(open>=0,'the open invoice must appear');
  // The proof state has to sit with its own invoice; a reader scanning the row
  // must not pick up the settled invoice's state by accident.
  assert.ok(html.indexOf('Awaiting verification')>open,
    'proof state must follow the invoice it belongs to');
  assert.match(html,/PAYNOW-8891/,'the payment reference must be visible for reconciliation');
});

test('contact actions exist exactly when there is a number to dial',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const CUI=localizedCUI(api);

  const [withPhone]=api.companyDetailContactRows(chasedFirm.contacts,CUI);
  assert.match(withPhone[3],/href="tel:/,'a contact with a number must be callable');
  assert.match(withPhone[3],/wa\.me\/6580000001/,'WhatsApp must use digits only');

  const [withoutPhone]=api.companyDetailContactRows(
    [{full_name:'No Number',phone:''}],CUI);
  assert.doesNotMatch(withoutPhone[3],/href="tel:|wa\.me/,
    'a contact with no number must not render a dead button');
  assert.match(withoutPhone[3],/No contact number/);
});

test('a firm with nothing on it renders empty states, never invented figures',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const html=api.companyDetailHtml({
    company:{id:'b-2',name:'New Firm',sector:'unclassified'},
    subscription:null,outstanding:{open_invoice_count:0,balance_due_cents:0},
    contacts:[],payments:[],consultant:null
  },localizedCUI(api));

  assert.match(html,/No subscription/);
  assert.match(html,/no subscription yet/i);
  assert.match(html,/No contacts recorded/);
  assert.match(html,/Nothing has been billed/);
  assert.match(html,/SGD 0\.00/,'a zero balance is shown as zero, not hidden');
  assert.doesNotMatch(html,/owes money/i,'a firm with no debt must not be flagged as owing');
});

test('the directory row opens the drawer and carries the id to open it with',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const [row]=api.companyRows([{id:'b-1',name:'Loyang Cafe',sector:'cafe',
    status:'active',collection_mode:'chase',days_until_due:-5,contact_phone:'+65 8000 0001'}],
    localizedCUI(api));
  assert.match(row[0],/data-company-open="b-1"/,
    'the company name must be the control that opens its own drawer');
});

test('every drawer string is real copy in Chinese and Malay',async()=>{
  const api=await loadConsole();
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    const html=api.companyDetailHtml(chasedFirm,localizedCUI(api));
    for(const english of ['Payment history','Awaiting verification','Outstanding',
      'Subscription start','Days outstanding','Paid logins','Balance']){
      assert.doesNotMatch(html,new RegExp(`>${english}<`),
        `${locale} still renders the English string ${english}`);
    }
  }
});
