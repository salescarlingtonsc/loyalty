/* V272 — one owner-marked screenshot of Reports -> Business Insights, three instructions.
   (A) "put top here": the From/To, Run report and Export sales CSV bar moves ABOVE the four
       category cards. A move, not a rebuild — every control id and handler stays single.
   (B) "remove this": the per-page branch select goes, exactly as V260 removed it from the Daily
       report and the Sales ledger, because the top bar already carries the one branch scope.
       Its "waiting for payment" notice carried a TRUE fact — an unpaid or switched-off branch is
       excluded from these figures — so that fact is restated once, next to the figures, instead
       of being dropped silently.
   (C) "delete this tab cause here have already": the Staff performance nav entry goes; the
       #/staffperf route, its page, and the Team performance card that links to it all stay. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const js = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing section start: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing section end: ${end}`);
  return source.slice(from, to);
}

const reports = section(js, 'async function reportsPage(){', '\n/* ---------- get started');

test('V272 (A) the report controls render above the four category cards', () => {
  const scopeCard = reports.indexOf('class="card report-scope-card"');
  const grid = reports.indexOf('<div class="report-decision-grid">');
  assert.notEqual(scopeCard, -1, 'the control bar is missing');
  assert.notEqual(grid, -1, 'the category card grid is missing');
  assert.ok(scopeCard < grid, 'the control bar must precede the category cards');
  // The four cards themselves are untouched by the move.
  for (const title of ['Sales & revenue', 'Appointments & busy times', 'Customer retention', 'Team performance']) {
    assert.ok(reports.includes(`title:'${title}'`), `missing category card: ${title}`);
  }
});

test('V272 (A) every control id and handler exists exactly once — moved, not duplicated', () => {
  for (const id of ['id="rf"', 'id="rt2"', 'id="rgo"', 'id="rcsv"', 'class="card report-scope-card"']) {
    assert.equal(reports.split(id).length - 1, 1, `${id} must appear exactly once`);
  }
  for (const handler of ["$('rgo').onclick", "$('rcsv').onclick", "$('rf').onchange=$('rt2').onchange"]) {
    assert.equal(reports.split(handler).length - 1, 1, `${handler} must be wired exactly once`);
  }
  // The report bodies the moved bar drives are still the same three, still single.
  for (const bodyId of ["bodyId:'rbody'", "bodyId:'busyBody'", "bodyId:'returningBody'"]) {
    assert.equal(reports.split(bodyId).length - 1, 1, `${bodyId} must appear exactly once`);
  }
});

test('V272 (B) the branch select and its notice are gone, and scope still comes from the top bar', () => {
  assert.doesNotMatch(reports, /id="branchWrap"/);
  assert.doesNotMatch(reports, /refreshBranchFilter\(/);
  assert.doesNotMatch(reports, /All branches \(consolidated\)/);
  assert.doesNotMatch(reports, /is waiting for payment, so its reports are not available yet/);
  // Same substitution V260 made on the Daily report and the Sales ledger.
  assert.match(reports, /branchId:selectedBranchId\|\|null/);
});

test('V272 (B) the excluded-branch truth the notice carried is restated next to the figures', () => {
  assert.match(reports, /id="reportScopeNoteV272"/);
  assert.match(reports, /renderReportScopeNoteV272\(isCurrent\)/);
  const note = section(js, 'function reportScopeNoteTextV272(', '\nfunction branchScopeErrorHintV217(');
  // It says what the figures DO cover...
  assert.match(note, /Figures below cover/);
  // ...and names any branch left out, reusing the one wording the removed notice used.
  assert.match(note, /branch\.active===false/);
  assert.match(note, /branchScopeUnavailableReasonV217/);
  // That wording, which the removed select rendered, still exists and is still the single source.
  assert.match(js, /is waiting for payment, so its reports are not available yet/);
  assert.equal(js.split('function branchScopeUnavailableReasonV217(').length - 1, 1);
  // The note is rendered once, from one declaration.
  assert.equal(js.split('async function renderReportScopeNoteV272(').length - 1, 1);
  assert.equal(js.split('function reportScopeNoteTextV272(').length - 1, 1);
});

test('V272 (C) Staff performance is gone from the nav rail', () => {
  const navGroups = js.match(/const NAVGROUPS=\[[\s\S]*?\n\];/)[0];
  assert.doesNotMatch(navGroups, /'staffperf'/);
  assert.match(navGroups, /label:'Reports',items:\['dailyreport','sales','expenses','pnl','reports','customerintel'\]/);
});

test('V272 (C) the #/staffperf route and the Team performance card link both survive', () => {
  // The route is still registered against its real page function.
  assert.match(js, /staffperf:staffPerfPage/);
  assert.match(js, /async function staffPerfPage\(/);
  // The card on this page is still the entry point the owner pointed at.
  assert.match(reports, /canReadModule\('staffperf'\)&&\{href:'#\/staffperf'/);
  assert.match(reports, /title:'Team performance'/);
  // The drill-down back-link inside the page still resolves too.
  assert.match(js, /href="#\/staffperf">← Staff performance/);
  // Module metadata and permission wiring are untouched, so the route stays authorisable.
  assert.match(js, /staffperf:\['staff','Staff performance'\]/);
  assert.match(js, /const FINANCE_MODULES=new Set\(\['expenses','pnl','staffperf'\]\)/);
  // With no nav entry of its own the rail still lights its group rather than going blank.
  assert.match(js, /pageKey==='staffperf'\?'reports'/);
});
