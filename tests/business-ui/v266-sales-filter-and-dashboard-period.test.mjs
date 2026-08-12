/* V266 — two owner screenshot reports from production.

   ITEM A, Sales & refunds, verbatim in red: "I tried to filter by dates & click apply but
   cannot, please solve!!!". Three separate defects made Apply read as a dead button:
     (a) Payment state filtered on `sales.paid`, a column that does not exist. Verified against
         production: GET /rest/v1/sales?paid=eq.true returns 400 / 42703 "column sales.paid
         does not exist", which fails the WHOLE ledger read and leaves the previous rows on
         screen.
     (b) The To boundary was `sgIso(to+'T23:59')`, so the last 59 seconds of the chosen day sat
         outside a range that named that very day.
     (c) Nothing on the card stated the range in force, so a re-query that legitimately matched
         the same rows was indistinguishable from nothing happening. Clear filters compounded
         it by resetting only the four non-date controls.

   ITEM B, Dashboard, verbatim with arrows from the Today-schedule date chip to the KPIs: "by
   right based on this date, there are no numbers, please show correct number based on that
   date". The arithmetic was NOT wrong. Checked against production for Cubbly
   (8492e8d6-8888-4383-ada0-7e1ed69f0caa) over the selected 12 Jul – 10 Aug 2026 range:
   25 valid visits, 234730 revenue cents, 6 new customers — exactly the figures on screen.
   The card simply never said which period it covered, sitting under an unrelated day picker.
   So the numbers stay and the period is stated. */
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

const sales = () => section(js, 'async function salesPage(){', '\n/* ---------- services ---------- */');
const dash = () => section(js, 'async function dashboard(){', '\n/* ---------- customers');

test('V266 A1 the Sales ledger never queries the non-existent sales.paid column', () => {
  const block = sales();
  // Production proof: PostgREST answers 42703 for this column, killing the whole read.
  assert.doesNotMatch(block, /eq\('paid'/);
  assert.doesNotMatch(block, /query=query\.eq\('paid',paid==='true'\)/);
  // Payment state is still offered, and is now derived from the payments ledger.
  assert.match(block, /id="salesPayment"/);
  assert.match(block, /fetchRowsByIds\('payments','sale_id',ids,'sale_id'\)/);
  assert.match(block, /rows=rows\.filter\(row=>settled\.has\(row\.id\)===\(paid==='true'\)\)/);
});

test('V266 A2 the date range is a half-open Singapore day window, so the To date covers its whole day', () => {
  const block = sales();
  assert.doesNotMatch(block, /sgIso\(to\+'T23:59'\)/);
  assert.doesNotMatch(block, /sgIso\(from\+'T00:00'\)/);
  assert.match(block, /if\(from\)query=query\.gte\('occurred_at',sgDateBoundary\(from,0\)\);/);
  assert.match(block, /if\(to\)query=query\.lt\('occurred_at',sgDateBoundary\(to,1\)\);/);
});

test('V266 A3 Apply filters always produces a visible result, even when the rows are unchanged', () => {
  const block = sales();
  assert.match(block, /id="salesFilterSummary"/);
  assert.match(block, /const salesFilterNoteV266=/);
  assert.match(block, /Showing \$\{rows\.length\} \$\{rows\.length===1\?'sale':'sales'\}/);
  // The button reports that it is working, and stops reporting it in a finally.
  assert.match(block, /CUI\.setButtonBusy\(applyButton,\{busy:true,label:'Applying…'\}\)/);
  assert.match(block, /\}finally\{\s*\n\s*if\(applyButton\?\.isConnected\)CUI\.setButtonBusy\(applyButton,\{busy:false\}\);/);
  // A failed read no longer leaves stale rows looking like the filtered answer.
  assert.match(block, /These filters could not be applied\. The rows below are unchanged\./);
});

test('V266 A4 Clear filters restores the dates too, and the four other filters still compose', () => {
  const block = sales();
  assert.match(block, /const salesDefaultToV266=sgDateInputValue\(\),salesDefaultFromV266=shiftSgDateInput\(salesDefaultToV266,-29\);/);
  assert.match(block, /\$\('salesFrom'\)\.value=salesDefaultFromV266;\$\('salesTo'\)\.value=salesDefaultToV266;/);
  assert.match(block, /\['salesCustomer','salesStaff','salesType','salesPayment'\]\.forEach\(id=>\$\(id\)\.value=''\)/);
  // Customer search, team member, sale type and payment state all still reach the same read.
  assert.match(block, /if\(staff\)query=query\.eq\('staff_id',staff\);/);
  assert.match(block, /if\(type\)query=query\.eq\('kind',type\);/);
  assert.match(block, /customerSearch\?\(sl\|\|\[\]\)\.filter/);
  assert.match(block, /\['salesStaff','salesType','salesPayment'\]\.forEach\(id=>\{const el=\$\(id\);if\(el\)el\.onchange=loadRecent\}\)/);
  // An inverted range is refused with a reason instead of a silent no-op.
  assert.match(block, /The From date is after the To date\./);
});

test('V266 A5 Sale type offers gift card, a kind that really exists in the sales ledger', () => {
  assert.match(sales(), /<option value="gift_card">Gift card<\/option>/);
});

test('V266 B1 the Performance KPIs still come from the applied dashboard range, unchanged', () => {
  const block = dash();
  // The owner's reading was wrong, so the arithmetic must not be "corrected" to match it.
  assert.match(block, /sb\.rpc\('get_dashboard_summary_v155',\{p_business:S\.biz\.id,p_from:from,p_to:to,\.\.\.scopePayload\}\)/);
  assert.match(block, /const from=dashboardRoot\.querySelector\('#df'\)\.value,to=dashboardRoot\.querySelector\('#dt'\)\.value;/);
  assert.match(block, /\{key:'visits',value:String\(d\.visits\|\|0\)/);
  assert.match(block, /\{key:'revenue',value:money\(d\.revenue_cents\|\|0\)/);
});

test('V266 B2 the Performance card states the period it covers, next to the numbers', () => {
  const block = dash();
  assert.match(block, /id="dashboardPerformancePeriod"/);
  // Written from the range the RPC was answered for, not from the inputs at paint time.
  assert.match(block, /performancePeriod\.textContent=workspaceTemplateTextV97\('performancePeriodRange',\{from:dashboardScheduleDayLabelV252\(from\),to:dashboardScheduleDayLabelV252\(to\)\}\)/ /* v281: routed through the v97 reviewed template so zh-CN/ms merchants read it translated */);
  // And it stops claiming a period once the inputs move but Apply has not been pressed.
  assert.match(block, /pendingPeriod\.textContent='Date range changed — press Apply\.'/);
});

test('V266/V294 B3 the Today-schedule day picker drives the Performance figures and says so', () => {
  /* V294 (owner markup 2026-08-12, arrow from this control to the Performance line: "I want
     date linked to data below") reversed the V266 disclaimer: a schedule-day pick now retargets
     the figures through the SAME #df/#dt + load() path the range pills use, and the helper
     states the new truth. */
  const block = dash();
  /* V295 retarget (owner markup 2026-08-13: "for date selected should reflect schedule &
     Performance"): the link now runs BOTH ways — a period pill or Apply moves the schedule card
     to that range's END day — so the helper says "linked", not "also sets". V294's direction is
     asserted unchanged below; the second direction is asserted alongside it. */
  assert.match(block, /Linked both ways with the figures below\./);
  assert.doesNotMatch(block, /Changes the bookings shown here only/);
  assert.match(block, /rangeFromV294\.value=date;rangeToV294\.value=date;/);
  assert.match(block, /button\.dataset\.d==='1'&&date===sgDateInputValue\(\)/);
  assert.match(block, /applyScheduleDayV252\(dashboardRoot\.querySelector\('#dt'\)\.value,false\)/);
  assert.match(block, /const appliedEndV295=dashboardRoot\.querySelector\('#dt'\)\.value;/);
  assert.match(block, /const applyScheduleDayV252=\(date,syncRangeV295=true\)=>/);
  assert.match(block, /if\(!syncRangeV295\)return;/);
  assert.match(block, /dashboard-schedule-scope-v266/);
  // The note wraps onto its own line at every width, including 390px.
  assert.match(html, /\.dashboard-schedule-scope-v266\{flex-basis:100%/);
  assert.match(html, /\.performance-heading\{flex-wrap:wrap\}/);
});
