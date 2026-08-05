import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const appHtml = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');
const customerUi = readFileSync(resolve(repoRoot, 'app/customer-ui.js'), 'utf8');

test('V164 sidebar terminology is merchant-facing', () => {
  assert.match(customerUi, /star:'m12 3 2\.8 5\.67/);
  assert.match(appHtml, /reports:\['reports','Business Insights'\]/);
  assert.match(appHtml, /\{key:'grow',icon:'star',label:'Programmes'/);
  /* V170 owner decision: Daily report (today's takings) was fully built and routed but
     absent from every nav group, so owners could not reach it. It now leads the money group. */
  assert.match(appHtml, /\{key:'money',icon:'reports',label:'Reports',items:\['dailyreport','sales','reports','customerintel','pnl','expenses','staffperf'\]\}/);
});

test('V164 Dashboard adds schedule glance and in-card KPI action labels', () => {
  assert.match(appHtml, /dashboard-schedule-glance/);
  assert.match(appHtml, /Today schedule/);
  assert.match(appHtml, /View bookings/);
  assert.match(appHtml, /Open calendar/);
  assert.match(appHtml, /buttonLabel:'View visits'/);
  assert.match(appHtml, /buttonLabel:'View revenue'/);
  assert.match(appHtml, /buttonLabel:'See new customers'/);
  assert.match(appHtml, /buttonLabel:'See inactive customers'/);
  assert.match(appHtml, /metric-action-label/);
});

test('V164 Dashboard uses clearer collapse persistence and loading labels', () => {
  assert.match(appHtml, /peekaa\.v164\.dashboard\.performance\.open/);
  assert.match(appHtml, /peekaa\.v164\.dashboard\.understand\.open/);
  assert.match(appHtml, /<span class="branch-loading-pill" aria-live="polite">Branch scope<\/span>/);
  assert.match(appHtml, /<span class="branch-loading-pill" aria-live="polite">Reporting scope<\/span>/);
});

test('V164 merchant insights are concise and remove duplicated revenue CTA', () => {
  assert.match(appHtml, /Revenue has started/);
  assert.match(appHtml, /Sales were recorded this period\. Keep recording activity to unlock a reliable trend\./);
  assert.match(appHtml, /Revenue has started',explanation:'Sales were recorded this period\. Keep recording activity to unlock a reliable trend\.',why:'',actions:\[\]/);
  assert.doesNotMatch(appHtml, /Separate indicators, not a fake score/);
});

test('V164 Reports page is renamed Business Insights and uses visual decision cards', () => {
  assert.match(appHtml, /<h1>Business Insights<\/h1>/);
  assert.match(appHtml, /Visual reports for revenue, bookings, retention and team activity\./);
  assert.match(appHtml, /report-decision-grid/);
  assert.match(appHtml, /report-decision-card/);
  assert.match(appHtml, /report-card-visual/);
  assert.match(appHtml, /tone:'appointments'/);
  assert.match(appHtml, /tone:'retention'/);
  assert.match(appHtml, /tone:'team'/);
});

test('V164 Staff Performance summary cards use concise visual ranking treatment', () => {
  assert.match(appHtml, /Rank staff by revenue, signed commission and sales records for the selected period\./);
  assert.match(appHtml, /staff-rank-card/);
  assert.match(appHtml, /rank-visual/);
  assert.match(appHtml, /Highest attributed revenue/);
  assert.match(appHtml, /Highest signed commission/);
  assert.match(appHtml, /Most revenue-qualified records/);
});

test('V164 Staff Members defaults to a staff-list-first tab structure', () => {
  assert.match(appHtml, /function enhanceStaffMembersTabsV164/);
  assert.match(appHtml, /Staff list/);
  assert.match(appHtml, /Invites &amp; access/);
  assert.match(appHtml, /staff-members-tab-panel/);
  assert.match(appHtml, /staff-members-add-top/);
  assert.match(appHtml, /enhanceStaffMembersTabsV164\(teamPanel\)/);
});

test('V164 Programmes removes persistent setup CTA and keeps categorised overview', () => {
  assert.match(appHtml, /<h1 id="growTitle">Programmes<\/h1>/);
  assert.match(appHtml, /Create and manage rewards, promotions and customer programmes\./);
  assert.match(appHtml, /<div class="v150-title-actions"><\/div>/);
  assert.match(appHtml, /Loyalty & rewards/);
  assert.match(appHtml, /Promotions & growth/);
  assert.match(appHtml, /Recurring value/);
  assert.doesNotMatch(appHtml, /<button type="button" class="btn grow-primary" id="growAutoSetup">Continue setup<\/button>/);
});
