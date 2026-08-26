import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V252 — two owner-approved corrections to the business app.
   1. Customer 360 "Activity history" is a TABLE (DATE / TYPE / ITEM / AMOUNT / STAFF).
   2. The Dashboard "Today schedule" card loses its subtitle and its second appointments
      button, and gains Today/Tomorrow tabs plus a date picker so any day can be viewed. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const css = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

const historyTable = (() => {
  const i = app.indexOf('function renderHistPage(history,n,offsetV468=0){');
  assert.ok(i > 0, 'renderHistPage must still exist');
  const j = app.indexOf('/* ---------- quick earn', i);
  return app.slice(i, j > i ? j : i + 9000);
})();

const scheduleLoader = (() => {
  const i = app.indexOf('async function loadDashboardScheduleGlanceV180');
  assert.ok(i > 0, 'the dashboard schedule loader must still exist');
  return app.slice(i, i + 3600);
})();

test('V378 activity history renders six headers in order, Earned among them', () => {
  assert.ok(historyTable.includes('cui-table-wrap'), 'must reuse the app table wrap');
  assert.ok(historyTable.includes('aria-label="Activity history"'));
  /* V267 (owner: sort arrows drawn beside AMOUNT and STAFF) superseded the plain-<th> literal —
     Date, Amount and Staff are now sort buttons. The five columns and their order still bind. */
  /* V378 (owner: "i still do not see a column to record transactions of points/stamp collected"):
     Earned joins them, between ITEM and AMOUNT, and its heading names the live unit. */
  const headers = `<thead><tr>${"${sortHeadV267('date','Date')}"}<th>Type</th><th>Item</th><th>${"${esc(activityEarnedHeadV378())}"}</th>${"${sortHeadV267('amount','Amount')}${sortHeadV267('staff','Staff')}"}</tr></thead>`;
  assert.ok(historyTable.includes(headers), 'DATE / TYPE / ITEM / EARNED / AMOUNT / STAFF, in that order');
  // The wrap is what makes the table scroll horizontally on a 390px phone instead of
  // forcing the whole page sideways; data-responsive drives the stacked mobile layout.
  assert.ok(historyTable.includes('data-responsive="true"'));
  ['Date', 'Type', 'Item', 'Amount', 'Staff'].forEach((label) => {
    assert.ok(historyTable.includes(`data-label="${label}"`), `${label} cell must carry its mobile label`);
  });
  assert.ok(!historyTable.includes('<ul class="c360-timeline">'), 'the stacked list markup is replaced');
});

test('every cell is read from a structured field, never parsed out of a display sentence', () => {
  // The builder in clientDetail() emits kind / saleKind / staff / service / plan / amount.
  /* nestly_v518: the sale's ITEM cell now names the goods (activityItemTextV267 -> the sale's own
     sale_items rows), falling back to the note and then to the kind word. The kind fallback moved
     into that helper; the rule this test exists for is unchanged and still holds — every one of
     those three sources is a structured FIELD, and none is recovered by taking a rendered
     sentence apart. */
  assert.ok(historyTable.includes('activityItemTextV267(h)'),
    'the ITEM cell is built by the helper, not by parsing text');
  assert.ok(app.includes("const text=items||note||String((h&&h.saleKind)||'sale').replace(/_/g,' ');"),
    'and that helper reads structured fields in order: lines, note, kind');
  assert.ok(historyTable.includes("h.service||'general visit'"));
  assert.ok(historyTable.includes('cell.staff'));
  assert.ok(!/\.split\(['"`] · /.test(historyTable) && !historyTable.includes('.match(/ — /'),
    'no display string may be taken apart to recover a column');
  // Appointments carry a staff name of their own, via the same roster map the sales rows use.
  assert.ok(app.includes("staff:staffName[a.staff_id]||null"),
    'appointment rows must resolve their own team member');
});

test('sales carry money and non-monetary rows carry an em dash, never a false zero', () => {
  assert.ok(historyTable.includes("const DASH_V252='—'"));
  assert.ok(historyTable.includes('${cell.amount||DASH_V252}'), 'a row with no money prints the em dash');
  assert.ok(historyTable.includes('${cell.staff||DASH_V252}'), 'a row with no team member prints the em dash');
  assert.ok(historyTable.includes('amount:money(amount)'), 'sale rows print money()');
  // Appointments, memberships and packages are not monetary rows in this feed.
  assert.ok(/type:'Appointment',[\s\S]{0,400}amount:''/.test(historyTable));
  assert.ok(/type:'Membership',[\s\S]{0,400}amount:''/.test(historyTable));
  assert.ok(/type:'Package',[\s\S]{0,400}amount:''/.test(historyTable));
});

test('the per-row Reverse control and its provenance notes survive the table', () => {
  assert.ok(historyTable.includes('data-reverse-kind="sale" data-reverse-id="${h.id}"'));
  assert.ok(historyTable.includes('data-reverse-kind="redemption" data-reverse-id="${h.id}"'));
  assert.ok(historyTable.includes('h.refusal_reason'), 'a refused reversal must still say why');
  assert.ok(historyTable.includes('Package session · reversal restores one session with no payment refund'),
    'package-session provenance must not be deleted');
  assert.ok(historyTable.includes('Net ${money(Number(h.net_amount_cents||0))}'),
    'the net-after-reversal figure must not be deleted');
  assert.ok(historyTable.includes('c360-act-note-v252'), 'notes render as a muted line under the row');
  assert.ok(app.includes('bindReversalButtons'), 'the existing binder still wires the buttons');
});

test('the paging control still drives the same renderer', () => {
  /* V468 (owner photo 19: "maximum 5 transactions and will be next page") replaced the cumulative
     "Show earlier" with a real pager, so the renderer now takes an OFFSET as well as a count and
     the control that drives it is Previous/Next rather than a grow-by-50 button. */
  assert.ok(app.includes("$('histBody').innerHTML=renderHistPage(history,C360_ACTIVITY_PAGE_V468,histPageV468*C360_ACTIVITY_PAGE_V468)"));
  assert.ok(app.includes('id="histPrevV468"') && app.includes('id="histNextV468"'), 'both directions exist');
  assert.ok(!app.includes('id="histMore"'), 'the grow-by-50 control is gone');
  assert.ok(app.includes('const C360_ACTIVITY_PAGE_V468=5;'), 'the owner asked for five');
});

test('the dashboard schedule card drops its subtitle and its second appointments button', () => {
  assert.ok(!app.includes('<h2>Bookings and appointments</h2>'), 'the subtitle line is struck out');
  assert.ok(!app.includes('>View bookings</a>'), 'the duplicate appointments button is struck out');
  /* V295 retarget (owner markup 2026-08-13: the heading said "Today schedule" above the words
     "Nothing booked on 13 Aug 2026"). The heading is still there — it now carries an id and is
     rewritten to name whichever day is on screen. */
  assert.ok(app.includes('<h2 class="eyebrow" id="dashboardScheduleHeadingV295">Today schedule</h2>'),
    'the card keeps a heading — the eyebrow is promoted, not deleted');
  assert.ok(app.includes("headingHostV295.textContent=dashboardScheduleHeadingTextV295(day)"),
    'and that heading follows the day being shown');
  assert.ok(app.includes('<a class="btn secondary" href="#/appointments">Open calendar</a>'),
    'Open calendar is the surviving action');
});

test('Today/Tomorrow tabs and a date picker exist and drive one piece of state', () => {
  assert.ok(app.includes('data-schedule-day-v252="0"') && app.includes('data-schedule-day-v252="1"'));
  assert.ok(/aria-pressed="true">Today</.test(app) && /aria-pressed="false">Tomorrow</.test(app),
    'the tabs are a segmented control, announced with aria-pressed');
  assert.ok(app.includes('<input type="date" id="dashboardScheduleDate"'));
  assert.ok(app.includes("tab.setAttribute('aria-pressed',on?'true':'false')"),
    'pressed state is recomputed from the shown date, so tab and picker cannot disagree');
  assert.ok(app.includes('if(scheduleDateInputV252&&scheduleDateInputV252.value!==date)scheduleDateInputV252.value=date'),
    'picking any date must move the input to that date');
  // Both routes must re-fetch through the same applier.
  assert.ok(app.includes('scheduleTabsV252.forEach(tab=>{tab.onclick=()=>applyScheduleDayV252(scheduleTabDateV252(tab))})'));
  assert.ok(app.includes('scheduleDateInputV252.onchange=()=>{'));
  assert.ok(app.includes('loadDashboardScheduleGlanceV180(dashboardRoot,appliedDashboardScopeV141.branchId,date)'),
    'the applier re-fetches with the chosen date');
});

test('the schedule fetch is parameterised by an SGT calendar date', () => {
  assert.ok(app.includes('async function loadDashboardScheduleGlanceV180(root,branchId=null,dateV252=null)'));
  assert.ok(scheduleLoader.includes('const day=dateV252||sgDateInputValue()'), 'today is the default day');
  assert.ok(scheduleLoader.includes('sgDateBoundary(day),to=sgDateBoundary(day,1)'),
    'the window is anchored to Singapore time, never to browser-local midnight');
  assert.ok(app.includes("shiftSgDateInput(sgDateInputValue(),Number(tab.dataset.scheduleDayV252)||0)"),
    'Tomorrow is derived with the SGT day-shift helper');
  assert.ok(scheduleLoader.includes("timeZone:'Asia/Singapore'") || app.includes("dashboardScheduleDayLabelV252"),
    'the day label is formatted in Singapore time');
});

test('a chosen day is stale-guarded and never rendered as an unexplained blank', () => {
  assert.ok(app.includes('let dashboardScheduleEpochV252=0'));
  assert.ok(scheduleLoader.includes('const epochV252=++dashboardScheduleEpochV252'));
  assert.ok(scheduleLoader.includes('epochV252===dashboardScheduleEpochV252'),
    'a slower earlier day must not paint over the day being viewed');
  assert.ok(scheduleLoader.includes('if(!isCurrentScheduleV252())return'), 'the guard runs after the await');
  assert.ok(scheduleLoader.includes('Nothing booked on ${esc(dayLabelV252)}'),
    'an empty day gets a short muted line, not a blank');
  assert.ok(scheduleLoader.includes('dashboardScheduleRetry') && scheduleLoader.includes('loadDashboardScheduleGlanceV180(root,branchId,day)'),
    'a failed read stays retryable on the SAME day, and is never shown as an empty schedule');
});

test('the Performance range picker is not disturbed by the new schedule date input', () => {
  assert.ok(app.includes("dashboardRoot.querySelectorAll('.dashboard-range input[type=\"date\"]')"),
    'the range handler must be scoped, or changing the schedule day would invalidate the KPIs');
});

test('the new markup carries its styling', () => {
  assert.ok(css.includes('.dashboard-schedule-controls-v252'));
  assert.ok(css.includes('.c360-act-note-v252'));
  assert.ok(css.includes('.c360-act-amt-v252'));
});
