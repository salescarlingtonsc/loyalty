/* V260 — five owner-annotated UI fixes in Reports and Staff Members.
   (1) Daily report: remove the per-page branch picker and "waiting for payment" notice;
       scope still comes from the top bar (selectedBranchId).
   (2) Sales & refunds: remove the per-page Branch filter; scope still comes from the top bar.
   (3) Business Insights: fold the three "…answer" collapsibles into their matching decision
       card instead of leaving them as separate sections lower on the page.
   (4) Business Insights: the Team performance card leads to the real Staff performance route.
   (5) Staff Members: remove the "Working hours" card; fix the two staff tables sharing one
       column layout so status pills stop colliding with POSITION/COMMISSION. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const js = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');

function section(source, start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(from, -1, `missing section start: ${start}`);
  assert.notEqual(to, -1, `missing section end: ${end}`);
  return source.slice(from, to);
}

test('V260 (1) Daily report has no per-page branch picker, and still scopes from the top bar', () => {
  const daily = section(js, 'async function dailyReportPage(){', '\n/* ---------- expenses ---------- */');
  // The struck-out control and its "waiting for payment" notice are gone.
  assert.doesNotMatch(daily, /id="branchWrap"/);
  assert.doesNotMatch(daily, /refreshBranchFilter\(/);
  assert.doesNotMatch(daily, /is waiting for payment, so its reports are not available yet/);
  // Scope is still derived straight from the top-bar-owned selectedBranchId, unchanged.
  assert.match(daily, /branchId:selectedBranchId\|\|null/);
  // A branch change at the top bar re-enters this page via route() (hydrateProfileBranchSelectorV158),
  // so the initial load only needs to run once, directly.
  assert.match(daily, /invalidate\(\);load\(\);/);
});

test('V260 (2) Sales & refunds has no Branch filter, and still scopes from the top bar', () => {
  const sales = section(js, 'async function salesPage(){', '\n/* ---------- services ---------- */');
  assert.doesNotMatch(sales, /id="salesBranch"/);
  assert.doesNotMatch(sales, /label for="salesBranch"/);
  assert.doesNotMatch(sales, /saleBranches/);
  assert.doesNotMatch(sales, /initialSaleBranch/);
  // Every other filter is still wired: From/To, Team member, Sale type, Payment state, Customer
  // search, and the Apply/Clear buttons.
  for (const survivor of ['id="salesFrom"', 'id="salesTo"', 'id="salesStaff"', 'id="salesType"',
    'id="salesPayment"', 'id="salesCustomer"', 'id="salesApply"', 'id="salesClear"']) {
    assert.match(sales, new RegExp(survivor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  // The query is scoped by the top bar's selectedBranchId, not a removed local control.
  assert.match(sales, /if\(selectedBranchId\)query=query\.eq\('branch_id',selectedBranchId\);/);
});

test('V260 (3) Business Insights folds the three answer collapsibles into their matching card, not duplicated', () => {
  const reports = section(js, 'async function reportsPage(){', '\n/* ---------- get started');
  // Each non-href decision is now the <details> element itself — no separate button id and no
  // separate <details id="moneyDetails"> section elsewhere in the page.
  /* V294 (owner markup 2026-08-12): the merged <details> cards became TABS — one panel per
     report, same body ids, still no separate opener button. */
  assert.match(reports, /panelId:'reportPanelMoneyV294'/);
  assert.match(reports, /panelId:'reportPanelBusyV294'/);
  assert.match(reports, /panelId:'reportPanelReturningV294'/);
  assert.doesNotMatch(reports, /id:'moneyAnswer'/);
  assert.doesNotMatch(reports, /id:'busyAnswer'/);
  assert.doesNotMatch(reports, /id:'returningAnswer'/);
  // The shared panel template renders every report body exactly once — moved, not duplicated.
  assert.equal((reports.match(/id="\$\{item\.panelId\}"/g) || []).length, 1);
  assert.equal((reports.match(/<section class="report-panel-v294"/g) || []).length, 1);
  // The result bodies (rbody/busyBody/returningBody) still exist and are still what
  // runMoney/runBusy/runReturning target — only where they live in the DOM moved.
  assert.match(reports, /bodyId:'rbody'/);
  assert.match(reports, /bodyId:'busyBody'/);
  assert.match(reports, /bodyId:'returningBody'/);
  assert.match(reports, /target=\$\('rbody'\)/);
  assert.match(reports, /const target=\$\('busyBody'\)/);
  assert.match(reports, /const target=\$\('returningBody'\)/);
});

test('V260 (4) Business Insights Team performance card routes to the real Staff performance page', () => {
  const reports = section(js, 'async function reportsPage(){', '\n/* ---------- get started');
  assert.match(reports, /canReadModule\('staffperf'\)&&\{href:'#\/staffperf'/);
  assert.match(reports, /title:'Team Performance'/); /* V294 tab casing */
  // #/staffperf is a real registered route (staffPerfPage), not an invented one.
  assert.match(js, /staffperf:staffPerfPage/);
});

test('V260 (5a) Staff Members no longer shows the Working hours card, and the save handler is preserved', () => {
  assert.doesNotMatch(js, /<b>Working hours<\/b>/);
  assert.doesNotMatch(js, /id="staffRotaCardV228"/);
  assert.doesNotMatch(js, /Loading working hours…/);
  assert.doesNotMatch(js, />Save working hours</);
  // Handlers are kept (this editor exists nowhere else — see the V260 comment above
  // staffManualAddCard), just no longer invoked from the Staff Members page.
  assert.match(js, /async function loadStaffRotaV228\(\)\{/);
  assert.match(js, /async function saveStaffRotaV228\(\)\{/);
  assert.doesNotMatch(js, /loadTeam\(\);\s*\n\s*loadStaffRotaV228\(\);/);
});

test('V260 (5b) the two staff tables share one column layout, and pills sit apart from the row grid', () => {
  const staffRow = section(js, "const staffRowV209=s=>{", '\n    const rows=st||[];');
  // Pills/buttons render in their own row beneath the name/phone/email/position/commission
  // grid, instead of sharing a flex line with it — which is what let the grid shrink to a
  // different width per row (and per group) depending on how many pills/buttons a teammate had.
  assert.match(staffRow, /class="staff-row-actions"/);
  assert.doesNotMatch(staffRow, /class="row staff-row-line"/);
  const css = section(html, '.staff-row-line{', '.staff-col-v226{min-width:0;overflow-wrap:anywhere}');
  assert.match(css, /flex-direction:column/);
  assert.match(html, /\.staff-row-open\{[^}]*width:100%/);
  assert.doesNotMatch(html, /\.staff-row-open\{[^}]*flex:1 1 460px/);
  // Both "Owner & managers" and "Roster only" groups render the header + rows through the same
  // staffRowV209/staff-col-head-v226 template — one shared layout, not two.
  assert.equal((js.match(/const staffRowV209=s=>\{/g) || []).length, 1);
  assert.equal((js.match(/class="staff-col-head-v226"/g) || []).length, 1);
});
