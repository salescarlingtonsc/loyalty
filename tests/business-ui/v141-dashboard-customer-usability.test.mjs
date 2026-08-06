import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=(fs.readFileSync(path.join(repo,'app/index.html'),'utf8')+'\n'+fs.readFileSync(path.join(repo,'app/app.js'),'utf8'));

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}

const dashboard=section('async function dashboard(){','/* ---------- customers ---------- */');
const customers=section('async function clientsPage(){','async function clientDetail(id){');
const profile=section('async function clientDetail(id){','/* ---------- quick earn (');

test('V141 dashboard removes duplicate launchers and keeps branch-scoped performance visible',()=>{
  assert.match(app,/flat:'Dashboard',items:\['dashboard'\]/);
  assert.doesNotMatch(dashboard,/taskLauncher|task-launcher-grid|<details class="card performance-panel"/);
  assert.match(dashboard,/id="dashboardReportingScopeWrap"/);
  assert.match(dashboard,/renderReportingScopeSelectorV155\([^\n]+dashboardReportingScopeWrap/);
  assert.match(dashboard,/data-d="1"[^>]*>Today</);
  assert.match(dashboard,/class="performance-heading ux154-collapsible-head"[\s\S]*CUI\.icon\('reports'/);
  assert.doesNotMatch(dashboard,/performance-panel>summary|<summary>Performance/);
});

test('V141/V150 every visible KPI is a semantic drilldown with plain definitions',()=>{
  for(const key of ['visits','revenue','new','inactive']){
    assert.match(dashboard,new RegExp(`${key}:\\{label:`));
    assert.match(dashboard,new RegExp(`key:'${key}'`));
  }
  for(const removedKey of ['unique','points','credit']){
    assert.doesNotMatch(dashboard,new RegExp(`key:'${removedKey}'`));
  }
  assert.match(dashboard,/data-dashboard-metric="\$\{metric\.key\}"/);
  assert.match(dashboard,/Customer membership or customer records created during the selected period/);
  assert.match(dashboard,/Business-wide customers with no valid visit for at least 30 complete Singapore days/);
  assert.match(dashboard,/openDashboardMetricDetailV141/);
  assert.match(dashboard,/workspaceTemplateAttributeV97\('aria-label','viewDashboardMetricDetails'/);
  assert.match(dashboard,/appliedDashboardScopeV141/);
  assert.match(dashboard,/business-current/);
});

test('V141 charts communicate reconciled intensity, SGD and demographics while unsafe gross sale mix stays hidden',()=>{
  assert.match(dashboard,/dashboardWeekdayColoursV141/);
  assert.match(dashboard,/quiet/);
  assert.match(dashboard,/medium/);
  assert.match(dashboard,/busiest/);
  assert.match(dashboard,/Recorded gender/);
  assert.match(dashboard,/gender_counts/);
  assert.doesNotMatch(dashboard,/Services and goods sold|dashboardSaleMixV141|sale_items/);
  assert.match(dashboard,/ticks:\{callback:[^}]*SGD/);
  assert.match(dashboard,/CUI\.icon\('reports'/);
});

test('V141 dashboard load failures stay in context and can be retried',()=>{
  assert.match(dashboard,/id="dashboardStatus" aria-live="polite"/);
  assert.match(dashboard,/Performance data could not be loaded\./);
  assert.match(dashboard,/dashboardReportRetry/);
  assert.match(dashboard,/Inactive customer count could not be loaded\./);
  assert.match(dashboard,/dashboardInactiveRetry/);
  assert.doesNotMatch(dashboard,/Services and goods detail could not be loaded\./);
});

test('V141 core dashboard copy is localized in Chinese and Malay',()=>{
  for(const label of ['Visit entries','Revenue','Unique customers','New customers','Points issued','Credit liability','Busiest days','Performance data could not be loaded.','All business customers','All permitted branches','Current balance/status']){
    const occurrences=app.split(`'${label}':`).length-1;
    assert.ok(occurrences>=2,`${label} must appear in both workspace dictionaries`);
  }
  assert.match(dashboard,/workspaceTranslationV97\('All business customers'\)/);
  assert.match(dashboard,/workspaceTranslationV97\('All permitted branches'\)/);
  assert.match(dashboard,/workspaceTranslationV97\('Current balance\/status'\)/);
});

test('V141 customer directory exposes last-visit choice and date joined',()=>{
  assert.match(customers,/Show customers by last visit/);
  /* The customer directory must read through a tenant-scoped, versioned RPC rather than a raw
     table query. The VERSION deliberately is not pinned: this reader has moved v129 -> v154 ->
     v155 and each bump broke this assertion without anything actually regressing. What matters
     is the shape, so that is what is asserted. */
  assert.match(customers,/sb\.rpc\('staff_list_customers_v\d+'/);
  assert.match(customers,/formatCustomerJoinedDateV141\(c\.created_at\)/);
  assert.match(customers,/Date joined/);
  assert.match(customers,/formatCustomerJoinedDateV141/);
  assert.match(customers,/Never visited/);
});

test("V141 customer profile presents Peekaa's suggestion, expiry and an icon-led rewards card",()=>{
  assert.match(profile,/Peekaa(?:&apos;|')s suggestion/);
  assert.match(profile,/c360-points-expiry/);
  assert.match(profile,/nextExp\.remaining/);
  assert.match(profile,/staff_get_customer_actionable_loyalty_v145/);
  assert.match(profile,/const nextExp=loyaltyFacts\?\.expiry/);
  assert.match(profile,/Loyalty balances and reward availability are temporarily unavailable/);
  assert.match(profile,/c360LoyaltyRetry/);
  assert.match(profile,/class="c360-rewards-head"/);
  assert.match(profile,/CUI\.icon\('loyalty'/);
  assert.match(profile,/id="c360-loyalty"/);
});
