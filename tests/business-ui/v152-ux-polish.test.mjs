import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const cui = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const dashboard = section('async function dashboard()', 'async function clientsPage()');
const customers = section('async function clientsPage()', 'async function clientDetail');
const sales = section('async function salesPage()', 'async function servicesPage()');
const services = section('async function servicesPage()', 'async function referralsPage()');
const bookings = section('async function bookingsPage()', 'async function waitlistPage()');
const waitlist = section('async function waitlistPage()', '/* ---------- inventory ---------- */');
const packages = section('async function packagesPage()', '/* ---------- branches (owner-only) ----------');
const branches = section('async function branchesPage()', 'async function settingsPage()');
const reports = section('async function reportsPage()', 'async function pnlPage()');
const staffPerf = section('async function staffPerfPage', '/* ---------- daily report ---------- */');
const dailyReport = section('async function dailyReportPage()', '/* ---------- expenses ---------- */');
const expenses = section('async function expensesPage()', '/* ---------- P&L ---------- */');
const pnl = section('async function pnlPage()', 'async function settingsPage()');
const settings = section('async function settingsPage()', '  /* CSV import */');

test('V152 shared UI primitives include skeletons, guarded busy buttons and accessible empty states', () => {
  assert.match(cui, /function skeletonLine/);
  assert.match(cui, /function skeletonCard/);
  assert.match(cui, /function skeletonGrid/);
  assert.match(cui, /function tableSkeleton/);
  assert.match(cui, /function chartSkeleton/);
  assert.match(cui, /function formSkeleton/);
  assert.match(cui, /function setButtonBusy/);
  assert.match(cui, /aria-busy/);
  assert.match(cui, /cui-button-spinner/);
  assert.match(cui, /role="status"/);
});

test('V152 visual system has consistent responsive, reduced-motion and table polish hooks', () => {
  assert.match(app, /--motion-fast/);
  assert.match(app, /--control-h/);
  assert.match(app, /\.cui-skeleton/);
  assert.match(app, /prefers-reduced-motion:\s*reduce/);
  assert.match(app, /input,select,textarea\{font-size:16px/);
  assert.match(app, /table\[data-responsive="true"\]/);
  assert.match(app, /\.cui-empty/);
  assert.match(app, /\.btn\.is-loading/);
});

test('V152 key business pages use skeleton loading instead of generic spinners', () => {
  assert.match(dashboard, /CUI\.chartSkeleton\(\{title\}/);
  assert.match(dashboard, /\['Busiest days','Revenue over time','Age groups','Recorded gender'\]\.map\(title=>CUI\.chartSkeleton\(\{title\}\)\)/);
  assert.match(customers, /CUI\.tableSkeleton\(\{rows:5,columns:7\}\)/);
  assert.match(sales, /CUI\.tableSkeleton\(\{rows:6,columns:7\}\)/);
  assert.match(services, /CUI\.tableSkeleton\(\{rows:4,columns:5\}\)/);
  assert.match(bookings, /CUI\.tableSkeleton\(\{rows:3,columns:6\}\)/);
  assert.match(waitlist, /CUI\.skeletonGrid\(\{cards:2,lines:3\}\)/);
  assert.match(expenses, /CUI\.tableSkeleton\(\{rows:5,columns:8\}\)/);
  assert.match(pnl, /CUI\.chartSkeleton\(\{title:'Expenses by category'\}\)/);
  assert.match(packages, /CUI\.tableSkeleton\(\{rows:4,columns:5\}\)/);
  assert.match(branches, /CUI\.skeletonGrid\(\{cards:3,lines:3\}\)/);
  assert.match(settings, /CUI\.skeletonCard\(\{lines:5\}\)/);
});

test('V152 empty states explain what happened and what to do next', () => {
  for (const expected of [
    'No revenue recorded yet',
    'Record your first sale to start tracking business performance',
    'Customers will appear here after joining your loyalty programme or making a purchase',
    'No sales match these filters',
    'No waiting customers',
    'Walk-ins waiting for a seat will appear here',
    'Record business expenses to keep your P&L accurate',
    'Customer booking requests will appear here after customers use your booking link',
    'Add your first service so customers can book',
    'Sold packages will appear here after a customer purchases prepaid sessions',
    'Add your first branch so sales, bookings, staff access and reports can be scoped correctly'
  ]) {
    assert.ok(app.includes(expected), `missing V152 empty-state copy: ${expected}`);
  }
});

test('V152 touched forms guard against double submit with shared busy state', () => {
  assert.match(customers, /CUI\.setButtonBusy\(saveButton,\{busy:true,label:'Saving…'\}\)/);
  assert.match(services, /CUI\.setButtonBusy\(btn,\{busy:true,label:'Saving…'\}\)/);
  assert.match(waitlist, /CUI\.setButtonBusy\(btn,\{busy:true,label:'Adding…'\}\)/);
  assert.match(expenses, /CUI\.setButtonBusy\(addButton,\{busy:true,label:'Adding…'\}\)/);
  assert.match(branches, /CUI\.setButtonBusy\(\$\('brSave'\),\{busy:true,label:b\?'Saving…':'Creating…'\}\)/);
  assert.match(dailyReport, /CUI\.setButtonBusy\(button,\{busy:true,label:'Generating…'\}\)/);
});

test('V152 responsive tables are scoped to touched ledger and catalogue views', () => {
  for (const page of [sales, services, packages, staffPerf, dailyReport]) {
    assert.match(page, /class="cui-table-wrap"/);
    assert.match(page, /data-responsive="true"/);
  }
});

test('V152 removes legacy emoji empty states from polished business areas', () => {
  const forbidden = /<div class="big">(💸|🧾|🛠️|📅|🪑|🎫|🏢|🔒|🧑‍💼)/;
  for (const [name, source] of Object.entries({
    dashboard, customers, sales, services, bookings, waitlist, packages, branches, reports, pnl, staffPerf, dailyReport, expenses, settings
  })) {
    assert.doesNotMatch(source, forbidden, `${name} still contains a legacy emoji empty state`);
  }
});
