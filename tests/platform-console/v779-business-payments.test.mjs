/* nestly_v779 — the platform console reads a firm's payments, branch by branch.

   Owner, 2026-09-05 (three photos): a Case-won card in the onboarding kanban should open the
   company and show its transactions "broken down to each branch like how businesses see it",
   with a way straight into the firm record; the firm record itself carries the same payment
   history ("Cubbly SPA paid on 5 Sep 2026 · renews on 5 Sep 2027").

   The renderer is EXECUTED here (vm-loaded console, stub CUI) — a grep of the source would stay
   green while the grouping was wrong. The wiring (kanban click, firm record card, RPC name and
   scope) is pinned by source assertions, and the migration's guard and grants by its text. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,Intl,Date,Map,Set,Proxy,Reflect,JSON,Number,String,Array,RegExp};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}
const stubCUI=Object.freeze({
  icon:name=>`<i>${name}</i>`,
  card:({title,description,body})=>`<section><h2>${title}</h2><p>${description??''}</p>${body}</section>`,
  loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`
});

// Cafe 312 as it stood on 2026-09-05 after the owner's two payments: the plan on the main
// branch, Cafe 123 added and charged, and a capacity increase that belongs to no one branch.
const cafe312={
  business:{business_id:'b-312',name:'Cafe 312',slug:'cafe-312'},
  subscription:{provider_subscription_id:'sub_x',status:'active',cadence:'annual',
    current_period_start:'2026-09-05T09:59:01+00:00',current_period_end:'2027-09-04T16:00:00+00:00',
    customer_capacity:40000},
  branches:[
    {branch_id:'br-main',name:'Cafe 312',is_default:true,active:true,billing_state:'included'},
    {branch_id:'br-123',name:'Cafe 123',is_default:false,active:true,billing_state:'active'}
  ],
  invoices:[
    {provider_invoice_id:'inv_cap',status:'paid',paid_normalized:true,currency:'SGD',total_cents:100000,
      paid_at:'2026-09-05T10:17:19+00:00',reason:'capacity_increase',
      detail:{capacity_from:'10000',capacity_to:'40000',covers_from:'2026-09-05',covers_until:'2027-09-05'}},
    {provider_invoice_id:'inv_br',status:'paid',paid_normalized:true,currency:'SGD',total_cents:118800,
      paid_at:'2026-09-05T10:15:40+00:00',reason:'branch_added',provider_receipt_url:'https://rzp.io/r/abc',
      detail:{branch_id:'br-123',branch_name:'Cafe 123',covers_from:'2026-09-05',covers_until:'2027-09-05'}},
    {provider_invoice_id:'inv_init',status:'paid',paid_normalized:true,currency:'SGD',total_cents:118800,
      paid_at:'2026-09-05T09:59:01+00:00',reason:'initial',
      detail:{covers_from:'2026-09-05',covers_until:'2027-09-05'}}
  ]
};

test('v779 the renderer groups charges by branch and says paid-on / renews-on per branch', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const html=api.platformBusinessPaymentsHtmlV779(cafe312,stubCUI);
  // One block per branch, plus the whole-account block because a capacity increase exists.
  assert.match(html,/data-payments-group-v779="br-main"/);
  assert.match(html,/data-payments-group-v779="br-123"/);
  assert.match(html,/data-payments-group-v779="account"/);
  // The main branch's block carries the plan payment and the owner's sentence shape.
  const main=html.split('data-payments-group-v779="br-main"')[1].split('data-payments-group-v779=')[0];
  assert.match(main,/Paid on 5 Sept? 2026 · renews on 5 Sept? 2027/);
  assert.match(main,/Annual plan/);
  assert.match(main,/SGD 1188\.00/);
  assert.match(main,/Main branch/);
  // Cafe 123's block holds only its own charge, named for the branch, with the receipt link.
  const added=html.split('data-payments-group-v779="br-123"')[1].split('data-payments-group-v779=')[0];
  assert.match(added,/Branch Cafe 123/);
  assert.match(added,/Paid on 5 Sept? 2026 · renews on 5 Sept? 2027/);
  assert.match(added,/href="https:\/\/rzp\.io\/r\/abc"/);
  assert.doesNotMatch(added,/Capacity increase/);
  assert.doesNotMatch(added,/Annual plan/);
  // The capacity increase sits under the whole account with its sizes, and no "renews on" —
  // it is not a branch's own renewal.
  const account=html.split('data-payments-group-v779="account"')[1];
  assert.match(account,/Capacity increase · 10,000 → 40,000 profiles/);
  assert.match(account,/SGD 1000\.00/);
  assert.doesNotMatch(account,/renews on/);
});

test('v779 a branch with no charge yet says so, and no whole-account block appears without one', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const trial={business:{name:'Cubbly SPA'},subscription:{},
    branches:[{branch_id:'a',name:'Cubbly · Orchard',is_default:true,billing_state:'included'},
      {branch_id:'b',name:'abc',billing_state:'suspended'}],invoices:[]};
  const html=api.platformBusinessPaymentsHtmlV779(trial,stubCUI);
  assert.equal((html.match(/No payment yet/g)||[]).length,2);
  assert.match(html,/Payment lapsed/);
  assert.doesNotMatch(html,/data-payments-group-v779="account"/);
});

test('v779 the grouping resolves a branch by id, then by name, and never drops a charge', async()=>{
  const api=await loadConsole();
  const branches=cafe312.branches;
  assert.equal(api.v779InvoiceGroupKey({reason:'branch_added',detail:{branch_id:'br-123'}},branches),'br-123');
  assert.equal(api.v779InvoiceGroupKey({reason:'branch_added',detail:{branch_name:'cafe 123'}},branches),'br-123');
  assert.equal(api.v779InvoiceGroupKey({reason:'branch_added',detail:{branch_name:'Gone'}},branches),'account');
  assert.equal(api.v779InvoiceGroupKey({reason:'initial'},branches),'br-main');
  assert.equal(api.v779InvoiceGroupKey({reason:null},branches),'br-main');
  assert.equal(api.v779InvoiceGroupKey({reason:'capacity_increase'},branches),'account');
  // detail may arrive as a JSON string from an older mirror row
  assert.equal(api.v779InvoiceGroupKey({reason:'branch_added',detail:'{"branch_id":"br-123"}'},branches),'br-123');
});

test('v779 the wording mirrors the business page', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  assert.equal(api.v779InvoiceWhat({reason:'branch_added',detail:{branch_name:'Cafe 123'}}),'Branch Cafe 123');
  assert.equal(api.v779InvoiceWhat({reason:'capacity_increase',detail:{capacity_from:'10000',capacity_to:'40000'}}),'Capacity increase · 10,000 → 40,000 profiles');
  assert.equal(api.v779InvoiceWhat({reason:'initial'},{cadence:'annual'}),'Annual plan');
  assert.equal(api.v779InvoiceWhat({reason:'initial'},{cadence:'monthly'}),'Monthly plan');
  assert.equal(api.v779InvoiceWhat({reason:null},{}),'Subscription');
});

test('v779 the firm record shows a Payments card, and a failed read degrades the card only', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const ok=api.v779PaymentsCardHtml({value:cafe312,error:null},stubCUI);
  assert.match(ok,/<h2>Payments<\/h2>/);
  assert.match(ok,/Annual plan · Active · 40,000 profiles · Renews on 5 Sept? 2027/);
  const failed=api.v779PaymentsCardHtml({value:null,error:{message:'boom'}},stubCUI);
  assert.match(failed,/Payments unavailable/);
});

test('v779 the kanban opens the company popup for a live firm and the firm record reads payments', async()=>{
  const source=await read('app/platform-console.js');
  // The onboarding board's card handler: a live firm no longer jumps to the Firms list.
  const handler=source.slice(source.indexOf("const open=()=>{"),source.indexOf("card.onclick=event=>{if(event.target.closest('[data-card-actions]'))return;open()}"));
  assert.match(handler,/_has_prospect_detail===false\)openCompanyPaymentsV779\(item,context\)/);
  assert.doesNotMatch(handler,/location\.hash='#\/platform\/firms'/);
  // The popup reads the v779 RPC and its button opens the firm record (photo 3).
  const popup=source.slice(source.indexOf('async function openCompanyPaymentsV779('),source.indexOf('async function openBusiness360V511('));
  assert.match(popup,/rpc\(sb,'platform_get_business_payments_v779',\{p_business:businessId\}\)/);
  assert.match(popup,/data-open-firm-record-v779\]'\)\.onclick=\(\)=>\{close\(\);openScopedFirm\(item,context\)\}/);
  assert.doesNotMatch(popup,/\.insert\(|\.update\(|\.delete\(/);
  // The firm record reads the same RPC alongside its three reports, tolerant of failure.
  const firm=source.slice(source.indexOf('async function openScopedFirm('),source.indexOf('async function renderScopedFirms('));
  assert.match(firm,/rpc\(sb,'platform_get_business_payments_v779',\{p_business:businessId\}\)\.then\(/);
  assert.match(firm,/v779PaymentsCardHtml\(paymentsV779,CUI\)/);
});

test('v779 the migration is a STABLE read open to a super admin or an assigned consultant only', async()=>{
  const sql=await read('db/migrations/20261006_nestly_v779_platform_business_payments.sql');
  assert.match(sql,/create or replace function public\.platform_get_business_payments_v779\(p_business uuid\)/);
  assert.match(sql,/\nstable\n/);
  assert.match(sql,/if not \(app\.is_super_admin\(\) or app\.platform_firm_report_access_v94\(p_business\)\) then/);
  assert.match(sql,/errcode='42501'/);
  assert.match(sql,/revoke all on function public\.platform_get_business_payments_v779\(uuid\) from public, anon;/);
  assert.match(sql,/grant execute on function public\.platform_get_business_payments_v779\(uuid\) to authenticated, service_role;/);
  assert.doesNotMatch(sql,/\binsert into\b|\bupdate public\.|\bdelete from\b/);
  // The invoice row carries the reason and detail the console groups on.
  assert.match(sql,/i\.reason, i\.detail/);
  const mirror=await read('supabase/migrations/20261006040000_nestly_v779_platform_business_payments.sql');
  assert.equal(mirror,sql,'both migration copies must be byte-identical');
});

test('v779 every new console string has a zh-CN and an ms translation', async()=>{
  const api=await loadConsole();
  const keys=['Payments by branch','Open firm record','Whole account','No payment yet',
    'Paid on {paid} · renews on {renews}','Paid on {paid}','Payments unavailable','Capacity increase',
    'Annual plan','Monthly plan','Renews on {date}','Read-only · the same charges the business sees on its Subscription page'];
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const key of keys){
      assert.notEqual(api.platformText(key),key,`${locale} is missing a translation for "${key}"`);
    }
  }
  api.setPlatformLocaleForTest('en');
});
