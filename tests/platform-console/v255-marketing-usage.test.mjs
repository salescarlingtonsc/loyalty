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

// A minimal stand-in for CustomerUI, same shape as the other platform-console
// suites use, so table/card markup is inspectable without a real DOM.
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

const superAdminAccess={role:'super_admin',modulePerms:{}};
const salesStaffAccess={role:'sales_staff',modulePerms:{reports:'r'}};

test('the marketing route exists, is super-admin-only and hashes to /platform/marketing',async()=>{
  const api=await loadConsole();
  const route=api.routes.find(entry=>entry.key==='marketing');
  assert.ok(route,'a marketing route must be registered');
  assert.equal(route.hash,'#/platform/marketing');
  assert.equal(route.label,'Marketing usage');
  assert.equal(route.superAdminOnly,true);
});

test('visibleRoutes hides marketing from non-super-admin platform roles and shows it to a super admin',async()=>{
  const api=await loadConsole();
  const forStaff=api.visibleRoutes(salesStaffAccess).map(entry=>entry.key);
  assert.ok(!forStaff.includes('marketing'),'a sales_staff role must not see the marketing route');
  const forAdmin=api.visibleRoutes(superAdminAccess).map(entry=>entry.key);
  assert.ok(forAdmin.includes('marketing'),'a super_admin role must see the marketing route');
});

test('marketing sits inside the reports navigation group',async()=>{
  const api=await loadConsole();
  const allowedRoutes=api.visibleRoutes(superAdminAccess);
  const groups=api.platformNavigationGroups(allowedRoutes);
  const reportsGroup=groups.find(group=>group.key==='reports');
  assert.ok(reportsGroup,'a reports navigation group must exist for a super admin');
  // The route objects are constructed inside the vm sandbox realm, so their
  // arrays carry a different Array prototype than this test file's literals —
  // deepEqual on the arrays themselves would fail on realm identity, not
  // content. Comparing the joined keys sidesteps that without weakening the
  // assertion.
  const routeKeys=reportsGroup.routes.map(entry=>entry.key).join(',');
  assert.equal(routeKeys,'reports,marketing');
});

test('marketingUsageRows renders business, month, customers, campaigns and push-sent cells',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const [row]=api.marketingUsageRows([{
    business_id:'biz-1',business_name:'Loyang Cafe',month:'2026-07',
    customers:42,campaigns:5,push_sent:180
  }],localizedCUI(api));
  assert.match(row[0],/data-marketing-business="biz-1"/,
    'the business cell must carry the drill-in control');
  assert.match(row[0],/Loyang Cafe/);
  assert.equal(row[1],'2026-07');
  assert.equal(row[2],'42');
  assert.equal(row[3],'5');
  assert.equal(row[4],'180');
});

test('marketingCampaignRows renders "Not tracked" for null push metrics, never 0 or an em dash',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const [row]=api.marketingCampaignRows([{
    campaign_kind:'promotion',campaign_ref_id:'promo-1',campaign_label:'August Bundle',
    first_sent_at:'2026-08-01T01:00:00Z',recipients:120,
    in_app_sent:80,in_app_opens:33,push_sent:40,push_failed:2,
    push_delivered:null,push_opens:null
  }],localizedCUI(api));
  const [,,,,sent,delivered,failed,opens]=row;
  assert.equal(sent,'120','Sent must be in_app_sent + push_sent (80 + 40)');
  assert.doesNotMatch(delivered,/^0$/,'a null push_delivered must never render as 0');
  assert.doesNotMatch(delivered,/^—$/,'a null push_delivered must never render as an em dash');
  assert.equal(delivered,'Not tracked');
  assert.equal(failed,'2','push_failed is a real, tracked number and must render as-is');
  assert.match(opens,/33/,'in-app opens must remain a real number');
  assert.match(opens,/Not tracked/,'push opens must read as untracked, not as zero');
});

test('marketingCampaignRows sums in-app and push sends into the Sent column',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const [row]=api.marketingCampaignRows([{
    campaign_kind:'retention',campaign_ref_id:'ret-1',campaign_label:'Win-back',
    first_sent_at:'2026-08-01T01:00:00Z',recipients:50,
    in_app_sent:10,in_app_opens:4,push_sent:15,push_failed:0,
    push_delivered:null,push_opens:null
  }],localizedCUI(api));
  const [,,,,sent]=row;
  assert.equal(sent,'25','Sent must be in_app_sent + push_sent');
});

test('marketingNotTrackedLabel distinguishes a real zero from an untracked value',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  assert.equal(api.marketingNotTrackedLabel(null),'Not tracked');
  assert.equal(api.marketingNotTrackedLabel(undefined),'Not tracked');
  assert.equal(api.marketingNotTrackedLabel(0),'0');
  assert.equal(api.marketingNotTrackedLabel(7),'7');
});

test('marketing usage strings localize into Chinese',async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('zh-CN');
  assert.equal(api.platformText('Not tracked'),'未追踪');
  assert.equal(api.platformText('Marketing usage'),'营销使用情况');
  assert.notEqual(api.marketingNotTrackedLabel(null),'Not tracked');
});
