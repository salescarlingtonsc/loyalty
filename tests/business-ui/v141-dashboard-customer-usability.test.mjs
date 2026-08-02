import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=fs.readFileSync(path.join(repo,'app/index.html'),'utf8');

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}

const shell=section('function renderShell(page){','/* ---------- dashboard ---------- */');
const dashboard=section('async function dashboard(){','/* ---------- customers ---------- */');
const customers=section('async function clientsPage(){','async function clientDetail(id){');
const profile=section('async function clientDetail(id){','/* ---------- quick earn (');

test('V141 dashboard removes duplicate launchers and keeps branch-scoped performance visible',()=>{
  assert.match(app,/flat:'Dashboard',items:\['dashboard'\]/);
  assert.doesNotMatch(dashboard,/taskLauncher|task-launcher-grid|<details class="card performance-panel"/);
  assert.match(shell,/page\[0\]==='dashboard'[\s\S]*id="dashboardBranchWrap"/);
  assert.match(dashboard,/refreshBranchFilter\([^\n]+dashboardBranchWrap/);
  assert.match(dashboard,/data-d="1"[^>]*>Today</);
  assert.match(dashboard,/class="performance-heading"[\s\S]*CUI\.icon\('reports'/);
  assert.doesNotMatch(dashboard,/performance-panel>summary|<summary>Performance/);
});

test('V141 every KPI is a semantic drilldown with plain definitions',()=>{
  for(const key of ['visits','revenue','unique','new','points','credit','inactive']){
    assert.match(dashboard,new RegExp(`${key}:\\{label:`));
    assert.match(dashboard,new RegExp(`key:'${key}'`));
  }
  assert.match(dashboard,/data-dashboard-metric="\$\{metric\.key\}"/);
  assert.match(dashboard,/Distinct identified customers attached to a sale entry in this selected period/);
  assert.match(dashboard,/Business-wide customers with no valid visit for at least 30 complete Singapore days/);
  assert.match(dashboard,/openDashboardMetricDetailV141/);
  assert.match(dashboard,/workspaceTemplateAttributeV97\('aria-label','viewDashboardMetricDetails'/);
  assert.match(dashboard,/appliedDashboardScopeV141/);
  assert.match(dashboard,/business-current/);
});

test('V141 charts communicate intensity, SGD, demographics and sale mix',()=>{
  assert.match(dashboard,/dashboardWeekdayColoursV141/);
  assert.match(dashboard,/quiet.*medium.*busiest/s);
  assert.match(dashboard,/Recorded gender/);
  assert.match(dashboard,/gender_counts/);
  assert.match(dashboard,/Services and goods/);
  assert.match(dashboard,/sale_items/);
  assert.match(dashboard,/canReadSaleItems=S\.myRole==='owner'\|\|S\.isSA===true/);
  assert.match(dashboard,/row\.item_type==='studio_discount'\|\|cents<=0/);
  assert.match(dashboard,/Visit-marked entries; reversals are separate/);
  assert.match(dashboard,/available to owners/);
  assert.match(dashboard,/dashboardSaleMixRetry/);
  assert.match(dashboard,/ticks:\{callback:[^}]*SGD/);
  assert.match(dashboard,/CUI\.icon\('reports'/);
});

test('V141 dashboard load failures stay in context and can be retried',()=>{
  assert.match(dashboard,/id="dashboardStatus" aria-live="polite"/);
  assert.match(dashboard,/Performance data could not be loaded\./);
  assert.match(dashboard,/dashboardReportRetry/);
  assert.match(dashboard,/Inactive customer count could not be loaded\./);
  assert.match(dashboard,/dashboardInactiveRetry/);
  assert.match(dashboard,/Services and goods detail could not be loaded\./);
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
  assert.match(customers,/select\('id,created_at'\)/);
  assert.match(customers,/<th>Date joined<\/th>/);
  assert.match(customers,/formatCustomerJoinedDateV141/);
  assert.match(customers,/Never visited/);
});

test("V141 customer profile presents Peekaa's suggestion, expiry and an icon-led rewards card",()=>{
  assert.match(profile,/Peekaa(?:&apos;|')s suggestion/);
  assert.match(profile,/c360-points-expiry/);
  assert.match(profile,/nextExp\.remaining/);
  assert.match(profile,/error:xbError/);
  assert.match(profile,/Expiry schedule is temporarily unavailable/);
  assert.match(profile,/c360ExpiryRetry/);
  assert.match(profile,/class="c360-rewards-head"/);
  assert.match(profile,/CUI\.icon\('loyalty'/);
  assert.match(profile,/id="c360-loyalty"/);
});
