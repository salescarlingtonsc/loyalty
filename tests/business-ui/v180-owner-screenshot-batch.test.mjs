import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V180: the batch of owner-annotated screenshot fixes (2026-08-06).
   Each assertion pins the specific way its change can silently rot. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

test('renaming the programme badge cannot empty the Running view', () => {
  // The row filter used to match the badge TEXT for "live". Renaming the badge to "Ongoing"
  // would have hidden every row in Running. The tone class is now the primary signal.
  assert.ok(app.includes("PROGRAMME_STATUS_LABEL_V180={Live:'Ongoing'}"), 'badge relabel missing');
  assert.ok(app.includes("pill?.classList.contains('on')"),
    'Running filter must key off the status tone, not the translated badge text');
  const i = app.indexOf("const isOngoing=pill?.classList.contains('on')");
  assert.ok(i > 0 && app.slice(i, i + 200).includes("status.includes('ongoing')"),
    'keep a text fallback for rows not built by programmeStatus');
});

test('programmes nav is one destination, and old hashes still resolve', () => {
  /* V250: the owner struck out the two remaining sub-rows, so the whole `const links=[…]`
     helper went with them — Programmes is one flat link onto the list. */
  assert.ok(app.includes("{key:'grow',icon:'star',flat:'Programmes',href:'#/grow'"),
    'Programmes must be one flat nav link');
  assert.ok(!app.includes('const links=['), 'the sub-nav link helper went with its rows');
  assert.ok(!app.includes("'Programmes list'"), 'the Programmes list row was struck out');
  assert.ok(!app.includes("['#/grow/ongoing'"), 'the Ongoing programmes row was struck out');
  assert.ok(!app.includes("['#/grow/available'"), 'the Pending setup row was struck out');
  // Deep links must not 404 just because the nav entry is gone.
  assert.ok(app.includes("['ongoing','available','settings'].includes(String(hashParam||''))"),
    'the removed hashes must still resolve to their views');
  assert.ok(!app.includes('class="programme-tabs"'), 'in-page tabs duplicated the sidebar');
});

test('#/grow lands on the full list, not a filtered view', () => {
  assert.ok(/includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list'/.test(app),
    'default programme view must be the full list');
  /* V245: the owner asked "Pending setup — where is it?", so the view names now match the
     nav row and the V244 tile group word-for-word. Same views, one vocabulary. */
  assert.ok(app.includes("'Pending setup':'List'"), 'list heading missing');
});

test('staff row carries every detail on one line and opens an editable profile', () => {
  const i = app.indexOf('const commissionSummary=');
  assert.ok(i > 0, 'commission summary missing from the staff row');
  /* Slice to the end of the row builder rather than a fixed byte count — V226 turned the row
     into a labelled grid and the extra markup pushed real fields outside a fixed window. */
  const row = app.slice(i, app.indexOf('const rows=st||[];', i));
  for (const field of ['s.email', 's.phone', 'ROLE_LABELS[s.role]', 'commissionSummary']) {
    assert.ok(row.includes(field), `staff row is missing ${field}`);
  }
  assert.ok(row.includes('toggleStaffProfile('), 'staff row must open a profile');
  assert.ok(app.includes('function staffProfilePanelHtml'), 'no profile panel');
});

test('blank commission stays NULL and 0% stays 0 — they mean different things', () => {
  const i = app.indexOf('window.saveStaffProfile=');
  const src = app.slice(i, i + 1400);
  assert.ok(src.includes("if(raw==='')return null"),
    'blank must persist as NULL ("not decided"), never coerced to 0');
  assert.ok(src.includes('Math.round(n*100)'), 'percent must convert to bps');
  assert.ok(src.includes('svc===undefined||prod===undefined'), 'out-of-range input must be rejected');
  assert.ok(!/patch=\{[^}]*role:/s.test(src),
    'role must not ride the plain UPDATE — set_staff_role_v74 re-derives module permissions');
  assert.ok(src.includes('window.chRole(staffId,nextRole)'), 'role change must go through the RPC');
});

test('staff performance shows two money cards, and the grid matches', () => {
  assert.ok(!app.includes("'Most revenue-qualified records'"), 'record-count card was removed');
  assert.ok(app.includes('.staff-rank-summary{display:grid;grid-template-columns:repeat(2,minmax(0,1fr))'),
    'grid still sized for three cards would leave a gap');
});

test('reports read as money in, money out, result, then why', () => {
  // V272 owner instruction ("delete this tab cause here have already"): Staff performance is no
  // longer a nav entry, so the order this test guards now ends at Customer intelligence.
  assert.ok(app.includes("items:['dailyreport','sales','expenses','pnl','reports','customerintel']"),
    'reports nav order not applied');
});

test('sales filter labels share one baseline', () => {
  assert.ok(app.includes('.sales-filter-row>div>label{margin:0 0 6px}'),
    'the global label margin is what pushed labels out of line');
  assert.ok(app.includes('.sales-filter-row{display:grid;grid-template-columns:repeat(4,minmax(150px,1fr));gap:10px;align-items:stretch}'),
    'align-items:end was half the misalignment');
});

test('waitlist funnel arrows never point at a wrapped line break', () => {
  assert.ok(app.includes('class="kpis wl-flow"'), 'waitlist kpis missing the flow class');
  assert.ok(app.includes('.wl-flow>*:not(:last-child)::after'), 'no chevrons');
  assert.ok(/@media\(min-width:900px\)\{\s*\.wl-flow\{grid-template-columns:repeat\(4/.test(app),
    'column count must be pinned so the arrow cannot straddle a wrap');
});

test('the four dashboard counters are individually coloured by meaning', () => {
  for (const key of ['visits', 'revenue', 'new', 'inactive']) {
    assert.ok(app.includes(`.dashboard-metric[data-dashboard-metric="${key}"]`),
      `no accent for the ${key} counter`);
  }
  const i = app.indexOf('.dashboard-metric[data-dashboard-metric="inactive"]');
  assert.ok(!app.slice(i, i + 120).includes('var(--red)'),
    'zero inactive customers is a good result and must not render as an alarm');
});

test('merchant insights sits outside the Performance section', () => {
  const perf = app.indexOf('id="dashboardPerformanceBody"');
  const understand = app.indexOf('id="dashboardUnderstandBody"');
  const insights = app.indexOf('id="dashboardInsights"');
  assert.ok(perf > 0 && understand > perf && insights > understand,
    'insights must render after Understand your business, not inside Performance');
});

test('today schedule glance shows real bookings and is fixed to today', () => {
  const i = app.indexOf('async function loadDashboardScheduleGlanceV180');
  assert.ok(i > 0, 'no schedule glance loader');
  const src = app.slice(i, i + 3600);
  // V252: the glance is no longer pinned to today — the owner added Today/Tomorrow tabs and a
  // date picker. What must still hold is that the day is a SINGAPORE calendar date (defaulting
  // to today) and that it is never widened by the Performance date range above it.
  assert.ok(src.includes("const day=dateV252||sgDateInputValue()") && src.includes("sgDateBoundary(day),to=sgDateBoundary(day,1)"),
    'the glance day must be an SGT calendar date, defaulting to today');
  assert.ok(!src.includes("dashboardRoot.querySelector('#df')"),
    'the glance must never read the Performance date range');
  assert.ok(src.includes("String(row.status||'').toLowerCase()!=='cancelled'"),
    'cancelled bookings must not be counted as people expected today');
  assert.ok(src.includes('dashboardScheduleRetry'),
    'a read failure must be retryable, never rendered as an empty schedule');
  assert.ok(!/if\(error\)[\s\S]{0,200}Nothing booked/.test(src),
    'an unread schedule and an empty schedule mean opposite things');
  assert.ok(src.includes('DASHBOARD_SCHEDULE_CHIP_LIMIT_V180') && src.includes('+${overflow} more'),
    'truncation must be explicit, never silent');
});

test('the glance takes its branch scope as an argument, not from a closure it cannot see', () => {
  // appliedDashboardScopeV141 is declared inside dashboard(); reading it from this
  // module-level function threw a ReferenceError.
  // V252: a third parameter (the day to show) was added; branchId is still an argument.
  assert.ok(app.includes('async function loadDashboardScheduleGlanceV180(root,branchId=null,dateV252=null)'));
  assert.ok(app.includes('loadDashboardScheduleGlanceV180(dashboardRoot,appliedDashboardScopeV141.branchId)'));
  const i = app.indexOf('async function loadDashboardScheduleGlanceV180');
  assert.ok(!app.slice(i, i + 3600).includes('appliedDashboardScopeV141'),
    'the loader must never reference the dashboard closure variable directly');
});

test('commission settings sit with the thing they belong to', () => {
  // Per-staff commission moved onto the staff row; the per-service override moved to Services.
  assert.ok(!app.includes('data-savestaff'), 'per-staff commission table should be gone');
  assert.ok(!app.includes('<b>Staff commission %</b>'), 'per-staff commission card should be gone');
  assert.ok(app.includes('<b>Service commission override %</b>'), 'service override must survive the move');
  const services = app.indexOf('async function servicesPage()');
  const mount = app.indexOf('<div id="commissionWrap"></div>');
  const bundles = app.indexOf('id="bundleSegmentBody"', services);
  assert.ok(services > 0 && mount > services && mount < bundles,
    'the override must mount inside the Services page');
  assert.ok(app.includes("if(!$('commissionWrap'))return"),
    'the loader must no-op where it has no mount point');
});
