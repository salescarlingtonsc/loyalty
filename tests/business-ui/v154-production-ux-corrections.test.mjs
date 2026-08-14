import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

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
  /* V225: the toolbar's own branch picker went — the top bar is the single control for which
     branch you are looking at, and two pickers on one screen contradicted each other. The staff
     filter is a genuine per-calendar filter and stays. */
  assert.doesNotMatch(appointments, /id="calendarBranch"/);
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
  /* V250: the owner made Programmes ONE flat nav link, so the group declares `flat` rather
     than `label`, and the old "Available programmes" sub-row is gone. The naming this test
     protects — that the module is called Programmes, not Grow — is unchanged. */
  /* V294: Programmes became a group (owner markup 2026-08-12), keeping the owner's word. */
  assert.match(nav, /label:'Rewards & Offer'/);
  assert.doesNotMatch(nav, /flat:'Programmes'/);
  assert.match(app, /Ongoing programmes/);
  /* V319 (owner markup 2026-08-14): the module is renamed "Rewards & Offer" — rail group and
     page heading together, per V245's own rule that the two must say the same words. The
     requirement this line protects is that the heading is the MODULE's name, not "Grow". */
  assert.match(grow, /<h1 id="growTitle">Rewards &amp; Offer<\/h1>/);
  /* V227 (owner: "all points reward in this tab") split "Loyalty & rewards" into two
     categories: Point system holds everything earned and spent in points, Other rewards
     holds the ones that do not use a balance. The behaviour this test protects — that the
     programme rows are categorised rather than one flat list — is unchanged. */
  /* V229 (owner: "square boxes for each topics then press in"; "instead of promotion & growth")
     restructured the overview into topic tiles and renamed the categories in the owner's own
     words. The categorisation these tests protect is unchanged. */
  assert.match(grow, /programme-category-title">Point system</);
  assert.match(grow, /programme-category-title">Lifestyle rewards</);
  /* V229: renamed to plain "Promotions" (the owner's word) and Referrals became its own
     category, so both remain distinct from the points work — which is the point here. */
  assert.match(grow, /programme-category-title">Promotions</);
  assert.match(grow, /programme-category-title">Referrals</);
  /* V229: renamed to say what is in it rather than what it is like. */
  /* V294: gift cards left the category (item 7b) — Memberships stands alone. */
  assert.match(grow, /programme-category-title">Memberships</);
  assert.doesNotMatch(grow, /Start automatically or choose the exact programme below/);
});

test('V154 tablet header uses responsive priority instead of clipping controls', () => {
  assert.match(app, /@media\(min-width:761px\) and \(max-width:1180px\)/);
  assert.match(app, /\.global-search input\{display:none\}/);
  assert.match(app, /\.workspace-language-picker\{display:none\}/);
  assert.match(app, /text-overflow:ellipsis/);
});
