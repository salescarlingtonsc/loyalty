import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

const dashboard = section('async function dashboard()', 'async function clientsPage()');
const customers = section('async function clientsPage()', 'async function clientDetail');
const appointments = section('async function appointmentsPage()', 'async function waitlistPage()');
const sales = section('async function salesPage()', 'async function servicesPage()');
const reports = section('async function reportsPage()', 'async function setupPage()');
const staff = section('async function staffPerfPage(drillId)', 'async function staffPerfDrill');
const grow = section('async function growPage(', 'function pbStatusChip');
const nav = section('const MODULES={', 'function navHtml');

test('V154 dashboard has greeting, compact dates and collapsible business sections', () => {
  assert.match(app, /\.ux154-section-toggle\{min-height:44px/);
  assert.match(dashboard, /dashboard-greeting/);
  assert.match(dashboard, /rawName\.split\(/);
  assert.match(dashboard, /dashboard-date-pair/);
  assert.match(dashboard, /dashboardPerformanceToggle/);
  assert.match(dashboard, /dashboardUnderstandToggle/);
  assert.match(app, /wireLocalCollapseV154/);
  assert.match(app, /peekaa\.v164\.dashboard\.performance\.open/);
  assert.match(app, /peekaa\.v164\.dashboard\.understand\.open/);
});

test('V154 merchant insights are concise and use customer-facing business health wording', () => {
  assert.match(app, /merchant-insights-context/);
  assert.match(app, /Business health/);
  assert.match(app, /customerCountTextV154/);
  assert.doesNotMatch(app, /fake score/);
  assert.doesNotMatch(app, /Separate indicators, not a fake score/);
});

test('V154 customers remove duplicate retention block and keep selected-audience actions', () => {
  assert.match(app, /\.client-summary-card b\{[^}]*color:var\(--coral\)/);
  assert.doesNotMatch(customers, /id="retentionReadiness"/);
  assert.doesNotMatch(customers, /Retention readiness/);
  assert.match(customers, /clientAudienceActions/);
  assert.match(app, /renderSelectedAudienceActionsV154/);
  assert.match(app, /Export this audience/);
  assert.match(app, /openCampaignPrepV153/);
});

test('V154 appointments separate calendar controls from list filters', () => {
  assert.match(appointments, /calendarOnlyControls/);
  assert.match(appointments, /appointmentListFilters/);
  assert.match(appointments, /appointmentListFrom/);
  assert.match(appointments, /appointmentListTo/);
  assert.match(appointments, /appointmentListStatus/);
  assert.match(appointments, /data-appt-preset="today"/);
  assert.match(appointments, /CUI\.icon\('branch'/);
  assert.match(appointments, /CUI\.icon\('staff'/);
  assert.match(appointments, /\.gte\('starts_at'/);
  assert.match(appointments, /\.lt\('starts_at'/);
});

test('V154 sales filters, dates and merchant-facing record status are present', () => {
  assert.match(sales, /sales-filter-panel/);
  assert.match(sales, /sales-filter-row/);
  assert.match(app, /sgLedgerDateV154/);
  assert.match(app, /timeZone:'Asia\/Singapore'/);
  assert.match(sales, /<th>Record status<\/th>/);
  assert.match(app, /saleRecordStatusV154/);
  assert.match(app, /Audit details/);
  assert.doesNotMatch(sales, /<th>Relationship<\/th>/);
});

test('V154 reports remove redundant shared filter copy while preserving controls', () => {
  assert.doesNotMatch(reports, /Shared report filters/);
  assert.doesNotMatch(reports, /Use one period and branch for every report category/);
  assert.match(reports, /Run report/);
  assert.match(reports, /Export sales CSV/);
});

test('V154 staff performance supports Today preset and explicit ranking basis', () => {
  assert.match(staff, /data-d="1">Today/);
  assert.match(staff, /staffPerfSort/);
  assert.match(staff, /staffPerfDir/);
  assert.match(staff, /Ranked by/);
  assert.match(staff, /Highest attributed revenue/);
  assert.match(staff, /Highest signed commission/);
  assert.match(staff, /Most revenue-qualified records/);
  assert.match(staff, /Rank/);
});

test('V154 Staff Members is a visible operations setup destination reusing settings team panel', () => {
  assert.match(nav, /staffmembers:\['staff','Staff Members'\]/);
  assert.match(nav, /label:'Operations setup'/);
  assert.match(app, /async function staffMembersPage\(\)/);
  assert.match(app, /settingsActiveTab='team'/);
  assert.match(app, /data-staff-members-page/);
});

test('V154 Programmes replaces Grow label and categorises programme rows', () => {
  assert.match(nav, /label:'Programmes'/);
  assert.match(app, /Ongoing programmes/);
  assert.match(app, /Available programmes/);
  assert.match(grow, /<h1 id="growTitle">Programmes<\/h1>/);
  assert.match(grow, /Loyalty & rewards/);
  assert.match(grow, /Promotions & growth/);
  assert.match(grow, /Recurring value/);
  assert.doesNotMatch(grow, /Start automatically or choose the exact programme below/);
});

test('V154 tablet header uses responsive priority instead of clipping controls', () => {
  assert.match(app, /@media\(min-width:761px\) and \(max-width:1180px\)/);
  assert.match(app, /\.global-search input\{display:none\}/);
  assert.match(app, /\.workspace-language-picker\{display:none\}/);
  assert.match(app, /text-overflow:ellipsis/);
});
