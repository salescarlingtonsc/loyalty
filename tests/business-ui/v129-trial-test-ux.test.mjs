import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migrationUrl=new URL(
  '../../supabase/migrations/20260801170000_nestly_v129_trial_test_ux.sql',
  import.meta.url
);
const migration=existsSync(migrationUrl)?readFileSync(migrationUrl,'utf8'):'';

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function declaredFunction(name){
  const start=app.indexOf(`function ${name}(`);
  assert.ok(start>=0,`missing function ${name}`);
  const bodyStart=app.indexOf('{',start);
  let depth=0;
  for(let i=bodyStart;i<app.length;i++){
    if(app[i]==='{')depth++;
    else if(app[i]==='}'&&--depth===0)return app.slice(start,i+1);
  }
  throw new Error(`unterminated function ${name}`);
}

const customers=section('async function clientsPage(){','async function clientDetail(id){');
const profile=section('async function clientDetail(id){','/* ---------- quick earn (');
const till=section('async function tillPage(){','async function salesPage(){');
const appointments=section('async function appointmentsPage(){','/* ---------- waitlist');
const generatedCopyStart=app.indexOf('const WORKSPACE_GENERATED_COPY_V97=');
const generatedCopyEnd=app.indexOf('const workspaceTextSourcesV97=',generatedCopyStart);
assert.ok(generatedCopyStart>=0&&generatedCopyEnd>generatedCopyStart,'missing generated localization corpus');
const executableApp=app.slice(0,generatedCopyStart)+app.slice(generatedCopyEnd);

test('customer-facing staff profile removes empty gender noise and explains rewards plainly',()=>{
  assert.doesNotMatch(customers,/<label for="cg">Gender|<th>Gender<\/th>|\$\{esc\(c\.gender/);
  assert.doesNotMatch(profile,/gender not set|\.gender/);
  assert.doesNotMatch(app,/<b>Customer gender<\/b>|labels:\['Female','Male','Other','Not set'\]/);
  assert.doesNotMatch(executableApp,/Columns (?:we recognise|recognised):[^\n<]*gender|iG=col\('gender'\)|p_gender:rec\.gender/);
  /* V226 renamed this card "Rewards for customer" — the owner's own wording. */
  /* V254: owner confirmed the annotation on the Mumu screenshot — the card is named
     "Available Customer Programmes". Same card, same gates; the label matches what it lists. */
  assert.match(profile,/<b>Available Customer Programmes<\/b>/);
  /* V226: the owner crossed the "How rewards work / Balance / Earn / Next reward" block out as
     "too confusing" and asked for redeemable rewards to lead instead. The facts this test
     protects — that staff can still see the balance, the earn rate and how far off the next
     reward is — are all still rendered; they are folded behind a summary rather than leading. */
  /* V249: heading renamed to the owner's wording. */
  assert.match(profile,/Redeem now!/);
  assert.match(profile,/<summary>Balance and earning<\/summary>/);
  assert.match(profile,/Balance:/);
  assert.match(profile,/Earn:/);
  assert.match(profile,/Nothing ready to redeem yet/);
  assert.match(profile,/<details[^>]+class="c360-reward-adjust"/);
  assert.match(profile,/<b>Activity history<\/b>/);
  assert.doesNotMatch(profile,/<b>Timeline<\/b>/);
});

test('all business-workspace sale entry points say Record sale while retaining the till route',()=>{
  const visibleSurfaces=[
    section('const MODULES=','const ROLE_LABELS='),
    section('function staffMobileActionsHtml(','function wireStaffMobileActions('),
    section('function globalActionsHtml(','function wireGlobalActions('),
    customers,profile,till,appointments
  ].join('\n');
  assert.doesNotMatch(visibleSurfaces,/Quick [Ee]arn/);
  assert.match(visibleSurfaces,/Record sale/);
  assert.match(profile,/nav\('#\/till'\)/);
  assert.match(till,/record_sale_by_phone|record_sale_catalogue_v94/);
  assert.match(app,/'Record sale':'记录销售'/);
  assert.match(app,/'Record sale':'Rekod jualan'/);
});

test('Customers exposes exact all, 30, 60 and 90 day inactivity filters backed by one reader',()=>{
  assert.match(customers,/id="clientInactivity"/);
  assert.match(customers,/<option value="">All customers<\/option>/);
  // The cumulative 30+/60+/90+ options became non-overlapping bucket cards, so a customer is
  // counted in exactly one band instead of in every band at or below their gap.
  for(const bucket of ['30_59','60_89','90_plus'])
    assert.match(customers,new RegExp(`data-inactive-bucket="${bucket}"`));
  assert.match(customers,/Inactive 30–59 days/);
  assert.match(customers,/sb\.rpc\('staff_list_customers_v155'/);
  // Bucket model: an explicit non-overlapping bucket key (p_inactive_bucket) instead of a
  // cumulative day count, and the helper is async.
  assert.match(customers,/const customerDirectoryPage=async\(search,inactiveBucket,offset\)=>/);
  assert.match(customers,/p_inactive_bucket:inactiveBucket/);
  assert.match(customers,/customerDirectoryPage\(customerRpcSearch,[\s\S]{0,40}clientPage\*CLIENT_PAGE_SIZE/);
  assert.match(customers,/Never visited/);
  assert.match(customers,/Last visit/);
  assert.match(migration,/create or replace function public\.staff_list_customers_v129/);
  assert.match(migration,/p_inactive_days is not null and p_inactive_days not in \(30,60,90\)/);
  assert.match(migration,/app\.can_module_read\(p_business,'clients'\)/);
  assert.match(migration,/sale\.counts_as_visit/);
  assert.match(migration,/reversal\.reversal_of=sale\.id/);
  assert.doesNotMatch(migration,/v106_sale_residual_minor/);
  assert.match(migration,/from page customer/);
  assert.match(migration,/revoke all on function public\.staff_list_customers_v129/);
  assert.match(migration,/grant execute on function public\.staff_list_customers_v129[\s\S]*to authenticated/);
});

test('appointment WhatsApp action creates a factual explicit-send link and no false receipt',()=>{
  const source=declaredFunction('appointmentWhatsAppUrlV129');
  const build=vm.runInNewContext(`(()=>{${source};return appointmentWhatsAppUrlV129})()`);
  const url=build({
    phone:'+65 8123 4567',businessName:'Glow Atelier',branchName:'Orchard',
    customerName:'Mei Lin',serviceName:'Spa Ritual 60',startsAt:'2026-08-03T06:00:00Z',
    staffName:'Chen Wei',status:'booked'
  });
  assert.ok(url.startsWith('https://wa.me/6581234567?text='));
  const message=decodeURIComponent(url.split('?text=')[1]);
  assert.match(message,/Glow Atelier/);
  assert.match(message,/Orchard/);
  assert.match(message,/Spa Ritual 60/);
  assert.match(message,/3 Aug 2026/);
  assert.match(message,/2:00 pm/);
  assert.match(message,/Chen Wei/);
  assert.equal(build({phone:'',businessName:'Glow Atelier'}),null);
  assert.equal(build({phone:'123',businessName:'Glow Atelier'}),null);
  assert.match(appointments,/Message on WhatsApp/);
  assert.match(appointments,/appointmentWhatsAppUrlV129/);
  assert.match(appointments,/WhatsApp opens with a draft/);
  assert.doesNotMatch(appointments,/WhatsApp (?:sent|delivered)|automatic WhatsApp reminder/i);
});
