/* nestly_v885 — the prospect/firm drawer for a CONVERTED firm, especially one billed by
   Stripe/Razorpay self-serve.

   Owner, 2026-09-10, "build all 5": a converted firm's drawer still asked for a quotation and a
   Stripe-checkout button it will never use once it is already a self-serve Stripe/Razorpay
   subscriber, still led with pre-sale Stage/Priority/Qualification fields on a merchant that has
   already been onboarded, and duplicated the Account tab as a second read of the same
   conversion_configuration fields the Audit tab already lists elsewhere. This test EXECUTES
   prospectDetailHtml (vm-loaded console, stub CUI) against three fixtures — converted+self-served,
   converted+manually-billed, and unconverted — so the shape of the generated HTML is pinned, not
   just the source text. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,JSON,Number,String,Array,RegExp,Math,encodeURIComponent,decodeURIComponent};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}
const stubCUI=Object.freeze({
  icon:name=>`<i data-icon="${name}"></i>`,
  card:({title,description,body})=>`<section><h2>${title}</h2><p>${description??''}</p>${body}</section>`,
  status:(text,tone)=>`<span class="status ${tone}">${text}</span>`,
  loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  emptyState:({title,body})=>`<div class="empty"><h3>${title}</h3><p>${body}</p></div>`,
  errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`,
  field:({id,label,value='',control='input',options=[],attributes=''})=>control==='select'
    ?`<label for="${id}">${label}</label><select id="${id}" ${attributes}>${options.map(option=>`<option value="${option.value}"${option.selected?' selected':''}>${option.label}</option>`).join('')}</select>`
    :`<label for="${id}">${label}</label><input id="${id}" value="${value}" ${attributes}>`
});

// Minimal fields every code path in prospectDetailHtml's first ~40 lines dereferences, with safe
// empty defaults, so any missing key added later shows up as an obvious throw rather than a
// silent `undefined` render.
function baseDetail(overrides={}){
  return {
    prospect:{id:'p1',current_stage_key:'activated',priority:'medium',converted_business_id:null,converted_at:null},
    company:{legal_name:'Kopi Lab Pte Ltd'},
    assignment:{},
    contacts:[],activities:[],tasks:[],
    operating_timeline:[],
    company_profile:{},qualification:{},
    commercial_terms:{},
    conversion_configuration:{workspace_name:'X'},
    documents:[],
    subscription_ops:{},
    audit:[],data_quality:{},stage_evidence:[],
    stage_history:[],
    sources:[],tags:[],
    onboarding:null,onboarding_error:null,onboarding_review:null,onboarding_review_error:null,
    billing_schedule:null,
    ...overrides
  };
}

test('converted + self-served (Stripe, no commercial terms): self-serve note, no quotation/checkout buttons, Account folded into Audit, Pre-sale history collapsed, no Stage row up top',async()=>{
  const {prospectDetailHtml}=await loadConsole();
  const detail=baseDetail({
    prospect:{id:'p1',current_stage_key:'activated',priority:'medium',converted_business_id:'b1',converted_at:'2026-08-01T00:00:00Z'},
    billing_schedule:{provider:'stripe',exists:true,editable:false}
  });
  const html=prospectDetailHtml(detail,stubCUI,true);
  assert.match(html,/This firm self-served through Stripe\./,'self-serve note is rendered');
  assert.match(html,/No quotation was needed\. Billing dates and modules are on the Controls tab\./);
  assert.doesNotMatch(html,/data-v156-quotation/,'no Generate quotation button');
  assert.doesNotMatch(html,/data-v156-checkout/,'no Create Stripe checkout button');
  assert.doesNotMatch(html,/id="detail-conversion"/,'no standalone Account section');
  assert.doesNotMatch(html,/\['detail-conversion','Account'\]/);
  const navSection=html.slice(0,html.indexOf('</nav>'));
  assert.doesNotMatch(navSection,/data-detail-section="detail-conversion"/,'no Account nav entry');
  assert.match(html,/Pre-sale history/,'nav label + summary both say Pre-sale history');
  assert.match(html,/<details class="card platform-detail-section platform-presale-history" id="detail-qualification">/);
  const auditSection=html.slice(html.indexOf('id="detail-audit"'));
  assert.match(auditSection,/Account setup record/,'account record folded into Audit');
  assert.match(auditSection,/<details class="platform-account-record">/);
  const overviewSection=html.slice(html.indexOf('id="detail-overview"'),html.indexOf('id="detail-company"'));
  assert.doesNotMatch(overviewSection,/<dt>Stage<\/dt>/,'no Stage row in the converted overview grid');
  assert.doesNotMatch(overviewSection,/<dt>Priority<\/dt>/,'no Priority row in the converted overview grid');
  // Billing recipients / subscription documents lists stay present regardless of self-serve.
  assert.match(html,/Add billing recipient/);
  assert.match(html,/Authorised billing recipients/);
  assert.match(html,/Subscription documents/);
  assert.match(html,/Sales contract &amp; billing documents/);
});

test('converted + manually billed (provider "manual"): terms grids and the quotation button are present',async()=>{
  const {prospectDetailHtml}=await loadConsole();
  const detail=baseDetail({
    prospect:{id:'p2',current_stage_key:'activated',priority:'high',converted_business_id:'b2',converted_at:'2026-08-01T00:00:00Z'},
    commercial_terms:{terms:{id:'ct1',product_code:'core',plan_code:'growth'}},
    billing_schedule:{provider:'manual',exists:true,editable:true}
  });
  const html=prospectDetailHtml(detail,stubCUI,true);
  assert.doesNotMatch(html,/This firm self-served through/);
  assert.match(html,/data-v156-quotation/,'Generate quotation button present');
  assert.match(html,/data-v156-checkout/,'Create Stripe checkout button present (converted_business_id set)');
  assert.match(html,/Product<\/dt>/,'terms grid rendered');
});

test('unconverted: Qualification label, Account tab and Configure account button all present, no Pre-sale history',async()=>{
  const {prospectDetailHtml}=await loadConsole();
  const detail=baseDetail();
  const html=prospectDetailHtml(detail,stubCUI,true);
  assert.doesNotMatch(html,/Pre-sale history/);
  assert.match(html,/data-detail-section="detail-qualification">Qualification</);
  assert.match(html,/<section class="card platform-detail-section" id="detail-qualification">/);
  assert.match(html,/data-detail-section="detail-conversion">Account</);
  assert.match(html,/id="detail-conversion"/);
  assert.match(html,/data-edit-conversion-config>Configure account/);
  const auditSection=html.slice(html.indexOf('id="detail-audit"'));
  assert.doesNotMatch(auditSection,/Account setup record/,'no folded account record for an unconverted prospect');
});
