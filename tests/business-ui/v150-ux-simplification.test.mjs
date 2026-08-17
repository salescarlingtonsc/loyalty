import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const html = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function sliceBetween(start, end) {
  const startIndex = html.indexOf(start);
  assert.notEqual(startIndex, -1, `missing start marker: ${start}`);
  const endIndex = html.indexOf(end, startIndex + start.length);
  assert.notEqual(endIndex, -1, `missing end marker: ${end}`);
  return html.slice(startIndex, endIndex);
}

const navBlock = sliceBetween('const NAVGROUPS=[', '];');
const dashboardBlock = sliceBetween('async function dashboard()', 'async function clientsPage()');
const customersBlock = sliceBetween('async function clientsPage()', 'async function clientDetail');
const tillBlock = sliceBetween('async function tillPage()', '/* ---------- sales ---------- */');
const salesBlock = sliceBetween('async function salesPage()', '/* ---------- services ---------- */');
const servicesBlock = sliceBetween('async function servicesPage()', 'async function packagesPage');
const appointmentsBlock = sliceBetween('async function appointmentsPage()', '/* ---------- waitlist (conversion queue) ----------');
const waitlistBlock = sliceBetween('async function waitlistPage()', 'async function branchesPage()');
const reportsBlock = sliceBetween('async function reportsPage()', 'async function setupPage()');
const expensesBlock = sliceBetween('async function expensesPage()', 'async function pnlPage()');
const pnlBlock = sliceBetween('async function pnlPage()', '/* ---------- settings ---------- */');

test('V150 sidebar keeps operational actions separate from money history', () => {
  /* V275: the Serve & sell group gained a bar-only "Bottles" row (bottle keep is a SaaS module
     exclusive to industry='bar' and is stripped from the resolved module list for every other
     sector before the rail is built). The doing-vs-reviewing separation this test guards is
     unchanged: Bottles is something staff DO during service, not money history. */
  /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely"): the Gift cards
     row left this group. The separation this test guards is unchanged. */
  assert.match(navBlock, /items:\['till','appointments',(?:'bottles',)?'bookings','waitlist'\]/);
  /* V180 owner instruction: Business Insights and Expenses swapped so the money group reads
     as money in -> money out -> result -> why. The separation this test guards is unchanged. */
  /* V272 owner instruction ("delete this tab cause here have already"): Staff performance left
     this nav; the #/staffperf route and the Business Insights card that reaches it are unchanged. */
  assert.match(navBlock, /items:\['dailyreport','sales','expenses','pnl','reports','customerintel'\]/);
});

test('V150 dashboard removes launch banner and keeps the requested KPI and chart structure', () => {
  assert.doesNotMatch(dashboardBlock, /dashboard-intro/);
  assert.match(dashboardBlock, /v150-titlebar/);
  assert.match(dashboardBlock, /New customer members/);
  assert.match(dashboardBlock, /Understand your business/);
  assert.match(dashboardBlock, /v150-dashboard-kpis/);
  assert.match(dashboardBlock, /v150-understand/);
  assert.doesNotMatch(dashboardBlock, /Customer records added/);
  assert.doesNotMatch(dashboardBlock, /Gross points earned/);
  assert.doesNotMatch(dashboardBlock, /Credit liability/);
});

test('V150 customers has mutually exclusive inactivity summaries and sortable customer columns', () => {
  assert.match(customersBlock, /Inactive 30–59 days/);
  assert.match(customersBlock, /Inactive 60–89 days/);
  assert.match(customersBlock, /Inactive 90\+ days/);
  assert.match(customersBlock, /customerBucketMatch/);
  assert.match(customersBlock, /sortable-th/);
  assert.match(customersBlock, /Date joined/);
});

test('V150 record sale highlights found customer context and interactive selectable items', () => {
  assert.match(tillBlock, /till-found-card/);
  assert.match(tillBlock, /Change branch or teammate/);
  /* V378 (owner, photo 4: the "Member since / Last visit" line struck through). The card keeps
     what identifies the person in front of the counter; their history is on the profile. */
  assert.doesNotMatch(tillBlock, /Last visit:|Member since:/);
  assert.match(tillBlock, /choice-button/);
});

test('V150 appointments separates Calendar/List and removes List from the day-week control', () => {
  assert.match(html, /\.v150-segment button\{min-height:44px/);
  assert.match(appointmentsBlock, /appointmentCalendarSeg/);
  assert.match(appointmentsBlock, /appointmentListSeg/);
  assert.match(appointmentsBlock, /day-now-line/);
  assert.doesNotMatch(appointmentsBlock, /\$\('vList'\)/);
  assert.doesNotMatch(appointmentsBlock, /id="vList"/);
});

test('V150 waitlist exposes active queue count in the sidebar badge source of truth', () => {
  assert.match(waitlistBlock, /setWaitlistBadgeCount\(queue\.length\)/);
  assert.match(html, /refreshWaitlistBadge/);
  assert.match(html, /data-waitlist-badge-slot/);
});

test('V150 sales is ledger-first and no longer includes the duplicate quick-sale form', () => {
  assert.match(salesBlock, /Sales ledger/);
  assert.match(salesBlock, /salesApply/);
  assert.match(salesBlock, /Record sale/);
  assert.doesNotMatch(salesBlock, /<b>Quick sale<\/b>/);
});

test('V150 reports uses plain-language report categories and run-report wording', () => {
  assert.match(reportsBlock, /<h1>Business Insights<\/h1>/);
  /* V294 (owner markup 2026-08-12): the four categories became a tab bar, and the owner
     renamed Appointments & busy times to Efficiency. Plain language survives as tab titles. */
  assert.match(reportsBlock, /Sales & Revenue/);
  assert.match(reportsBlock, /Efficiency/);
  assert.match(reportsBlock, /Customer Retention/);
  assert.match(reportsBlock, /Team Performance/);
  assert.match(reportsBlock, /Run report/);
  assert.doesNotMatch(reportsBlock, /Business answers/);
});

test('V150 expenses uses list/add segmentation instead of side-by-side panels', () => {
  assert.match(expensesBlock, /expenseListSeg/);
  assert.match(expensesBlock, /expenseAddSeg/);
  assert.match(expensesBlock, /showExpenseSegment\('list'\)/);
});

test('V150 P&L and Services use the simplified visual hierarchy and catalogue-first structure', () => {
  assert.match(pnlBlock, /v150-kpi/);
  assert.match(pnlBlock, /v150-soft-head/);
  assert.match(servicesBlock, /servicesSeg/);
  assert.match(servicesBlock, /bundlesSeg/);
  assert.match(servicesBlock, /Services catalogue/);
  assert.match(servicesBlock, /Bundles catalogue/);
  assert.doesNotMatch(servicesBlock, /<b>Resources<\/b>/);
});
