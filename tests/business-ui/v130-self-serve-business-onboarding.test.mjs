import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const migrationUrl=new URL(
  '../../supabase/migrations/20260801193000_nestly_v130_self_serve_business_onboarding.sql',
  import.meta.url
);
const migration=existsSync(migrationUrl)?readFileSync(migrationUrl,'utf8'):'';
const v132Migration=readFileSync(new URL(
  '../../supabase/migrations/20260801223000_nestly_v132_release_gap_closure.sql',
  import.meta.url
),'utf8');
const edge=readFileSync(new URL('../../supabase/functions/stripe-billing-command/index.ts',import.meta.url),'utf8');
const platform=readFileSync(new URL('../../app/platform-console.js',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function platformSection(start,end){
  const from=platform.indexOf(start),to=platform.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing platform section start: ${start}`);
  assert.ok(to>from,`missing platform section end: ${end}`);
  return platform.slice(from,to);
}

test('public business signup creates an owner account instead of requesting admin approval',()=>{
  const signup=section('function renderBusinessApplication(){','async function renderApprovedBusinessInviteSignup(');
  assert.match(signup,/Create your Nestly owner account/);
  assert.match(signup,/sb\.auth\.signUp/);
  assert.match(signup,/validNewPassword/);
  assert.match(signup,/I have read and agree to the Terms and Privacy Policy/);
  assert.doesNotMatch(signup,/Submit for approval|super admin must approve|public-business-application/);
});

test('signed-in owner chooses business, sector, cadence and capacity before Stripe',()=>{
  const onboard=section('function renderOnboard(){','/* ============================================================================');
  assert.match(onboard,/Set up your business/);
  assert.match(onboard,/ownerFullName/);
  assert.match(onboard,/businessName/);
  assert.match(onboard,/businessSector/);
  assert.match(onboard,/businessSlug/);
  assert.match(onboard,/value="annual"[^>]*checked/);
  assert.match(onboard,/value="monthly"/);
  assert.match(onboard,/customerCapacity/);
  assert.match(onboard,/Continue to secure Stripe Checkout/);
  assert.match(onboard,/start_self_serve_business_v130/);
  assert.match(onboard,/request_self_serve_checkout_v130/);
  assert.match(onboard,/stripe-billing-command/);
  assert.match(onboard,/GST not charged/);
  assert.doesNotMatch(onboard,/An approved invitation is required|Apply for a business account/);
});

test('payment-pending workspace is explicit and only provider-paid evidence activates it',()=>{
  const control=section('function renderBusinessWorkspaceControl(','/* ---------- auth ---------- */');
  assert.match(control,/Complete secure payment/);
  assert.match(control,/Payment confirmation pending/);
  assert.match(control,/get_self_serve_checkout_v130/);
  assert.match(migration,/create table public\.self_serve_business_onboarding_v130/);
  assert.match(migration,/create or replace function public\.start_self_serve_business_v130/);
  assert.match(migration,/create or replace function public\.request_self_serve_checkout_v130/);
  assert.match(migration,/create trigger billing_money_back_self_serve_activate_v130/);
  assert.match(migration,/new\.first_paid_at/);
  assert.match(migration,/approval_status='approved'/);
  assert.match(migration,/provider-confirmed self-service subscription payment/);
  assert.match(migration,/business_control_self_serve_payment_guard_v130/);
  assert.match(migration,/self-service approval is controlled by provider-confirmed payment/);
  assert.match(migration,/terms\.cadence=v_onboarding\.selected_cadence/);
  assert.match(migration,/terms\.customer_capacity=v_onboarding\.selected_customer_capacity/);
  assert.match(migration,/terms\.provider_base_price_id=catalog\.provider_base_price_id/);
  assert.match(migration,/invoice\.currency='SGD'/);
  assert.match(migration,/invoice\.tax_cents=0/);
  assert.match(migration,/invoice\.amount_remaining_cents=0/);
  assert.match(migration,/invoice\.total_cents=app\.self_serve_plan_total_v130/);
  assert.doesNotMatch(migration,/checkout\.session\.completed/);
});

test('self-service cannot offer or stage a sector that lacks the included Loyalty programme',()=>{
  assert.match(v132Migration,/V132 preflight: payment-pending self-service bundle lacks Loyalty/);
  assert.match(v132Migration,/create trigger self_serve_loyalty_bundle_guard_v132/);
  assert.match(v132Migration,/before insert or update of bundle_version_id,sector_key/);
  assert.match(v132Migration,/bundle\.status='published'/);
  assert.match(v132Migration,/'loyalty'=any\(bundle\.modules\)/);
  assert.match(v132Migration,/self-service launch requires a published Loyalty-capable sector/);
  assert.match(v132Migration,/perform set_config\(\s*'request\.jwt\.claim\.sub',v_onboarding\.owner_user_id::text,true/);
  assert.match(v132Migration,/perform set_config\('request\.jwt\.claim\.sub',coalesce\(v_prior_sub,''\),true\)/);
  assert.doesNotMatch(v132Migration,/grant (?:select|insert|update|delete) on/i);
});

test('Firm 360 initial load fetches the payment marker and exposes no manual decision',()=>{
  assert.match(platform,/get_self_serve_checkout_v130/);
  assert.match(platform,/self_service:asObject\(selfServePayload\)\.onboarding/);
  assert.match(platform,/paymentManaged=selfService\.status==='payment_pending'/);
  assert.match(platform,/Manual approval and rejection are disabled/);
  assert.match(platform,/approvalStatus!=='approved'&&!paymentManaged/);
  const initial=platformSection('    Promise.all([\n      fetchEnterpriseCustomerPage','  function reportCsvRows(');
  assert.match(initial,/get_self_serve_checkout_v130/);
  assert.match(initial,/self_service:asObject\(selfServePayload\)\.onboarding/);
});

test('Firm 360 renderer separates self-service payment from assisted approval',()=>{
  const source=platformSection('  function firmGovernanceHtml(','  function businessApprovalModal(');
  const render=new Function(
    'asObject','normalizePlatformPhone','pt','escapeHtml','workspaceControlTone',
    'moduleControlRows','platformStatus','asArray',
    `${source};return firmGovernanceHtml;`
  )(
    value=>value&&typeof value==='object'?value:{},()=>null,
    value=>String(value),value=>String(value??'').replaceAll('&','&amp;').replaceAll('<','&lt;'),
    ()=>'new',()=>'',value=>String(value),value=>Array.isArray(value)?value:[]
  );
  const CUI={
    status:(label)=>`<span>${label}</span>`,
    card:({title,body})=>`<article><h3>${title}</h3>${body}</article>`
  };
  const firm={name:'Radiant Skin Studio',branches:[]};
  const base={
    approval:{status:'pending',version:1},subscription:{state:'incomplete'},
    catalogue_intelligence:{enabled:false,version:1},workspace_access:false
  };
  const context={access:{role:'super_admin'}};
  const selfServe=render(firm,CUI,{...base,self_service:{status:'payment_pending'}},{},context);
  assert.match(selfServe,/Self-service signup is awaiting provider-confirmed payment/);
  assert.doesNotMatch(selfServe,/data-business-approval=/);
  const assisted=render(firm,CUI,{...base,self_service:null},{},context);
  assert.match(assisted,/Awaiting a super-admin decision/);
  assert.match(assisted,/data-business-approval="approved"/);
  assert.match(assisted,/data-business-approval="rejected"/);
});

test('completed Checkout redirects rotate before Stripe default expiry',()=>{
  assert.match(migration,/requested_at>now\(\)-interval '23 hours'/);
  assert.doesNotMatch(migration,/interval '2[4-9] hours'/);
});

test('Stripe returns self-service checkout to onboarding and retains ordinary owner Settings returns',()=>{
  assert.match(edge,/self_service_onboarding/);
  assert.match(edge,/\/business#\/onboarding\/payment\?status=processing/);
  assert.match(edge,/\/business#\/onboarding\/payment\?status=canceled/);
  assert.match(edge,/\/\#\/settings\?billing=processing/);
});
