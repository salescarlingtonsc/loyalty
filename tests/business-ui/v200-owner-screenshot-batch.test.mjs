import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V200 — three owner findings from one screenshot batch. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const indexHtml = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

/* ---------------------------------------------------------------- 1. the redundant headline */

/* Owner: "remove this redundant line 'SGD 1947.30 taken across 23 visits …'". The V170 headline
   restated the Revenue and Visits tiles directly beneath it, and its comparison sentence restated
   the per-tile delta chips. */
test('the dashboard headline that restated the tiles is gone', () => {
  assert.doesNotMatch(appJs, /taken across/);
  assert.doesNotMatch(appJs, /No earlier period to compare yet/);
  assert.doesNotMatch(appJs, /dashboardHeadline/);
  assert.doesNotMatch(indexHtml, /dashboard-headline/);
});

test('the figures the headline duplicated still have a home', () => {
  // the tiles keep the numbers…
  assert.match(appJs, /\{key:'revenue',value:money\(d\.revenue_cents\|\|0\)/);
  assert.match(appJs, /\{key:'visits',value:String\(d\.visits\|\|0\)/);
  // …and the delta chip keeps the comparison the sentence was making
  assert.match(appJs, /function dashboardDeltaChipV170\(change,previousFrom,previousTo\)/);
  // the range label is still used by the tile hints, so it must survive
  assert.match(appJs, /function dashboardRangeLabelV170\(from,to\)/);
});

/* ------------------------------------------------------- 2. unclickable calendar appointments */

/* Owner: "in calendar - not able to click in the specific appointments to edit or change staff".
   The handler was always bound; the blocked-time overlay was covering the buttons. `.week-…` and
   `.day-blocked-window` are both single-class selectors, so specificity ties and SOURCE ORDER
   decides — the week overrides sat ~760 lines too early and lost every declaration to the base
   rule, inheriting z-index:4 over .calendar-event's 2. */
test('the week blocked-time override wins the cascade it is meant to win', () => {
  const day = indexHtml.indexOf('.day-blocked-window{');
  const week = indexHtml.indexOf('.week-blocked-window{');
  assert.ok(day > 0 && week > 0, 'both rules must exist');
  assert.ok(week > day,
    'equal specificity means source order decides: the week override must come after the base rule');
});

test('a blocked window cannot sit above, or swallow a click meant for, an appointment', () => {
  assert.match(indexHtml, /\.week-blocked-window\{[^}]*z-index:1[^}]*\}/);
  assert.match(indexHtml, /\.week-blocked-window\{[^}]*pointer-events:none[^}]*\}/);
  const event = indexHtml.match(/\.calendar-event\{[^}]*z-index:(\d+)/);
  assert.ok(event && Number(event[1]) > 1, 'appointments must stack above blocked windows');
  // the week variant renders no Remove control, so it has nothing to receive a click for
  assert.doesNotMatch(appJs, /week-blocked-window[^`]*<button/);
});

test('the click handler the overlay was blocking is still wired for every calendar view', () => {
  assert.match(appJs, /routeMain\.querySelectorAll\('\[data-appointment\]'\)\.forEach\(button=>button\.onclick=/);
  // week, day, agenda and list all render the same data-appointment contract
  assert.ok((appJs.match(/data-appointment="\$\{a\.id\}"/g) || []).length >= 3);
});

/* --------------------------------------------------------------- 3. sub-module tabs */

/* Owner: "in all the modules i need you to simplify the sub modules … just tab the sub modules
   and can view easily instead of long scrolling", pointing at the Bookings pill strip. */
test('one declarative mechanism, so a page opts in by tagging rather than by wiring', () => {
  assert.match(appJs, /function sectionTabsV200\(root,\{key='',label='Sections'\}=\{\}\)/);
  assert.match(appJs, /Array\.from\(root\.children\)\.filter\(node=>node\.dataset&&node\.dataset\.subtab\)/);
  assert.match(appJs, /if\(groups\.length<2\)return null;/,
    'a page with one group must keep scrolling rather than grow a pointless strip');
});

test('untagged sections stay pinned above the strip', () => {
  // the strip is inserted at the FIRST TAGGED section, so anything before it keeps its place
  assert.match(appJs, /groups\[0\]\.nodes\[0\]\.before\(strip\);/);
  assert.match(appJs, /strip\.after\(\.\.\.panels\);/);
});

test('the strip is a real tablist, not styled buttons', () => {
  assert.match(appJs, /strip\.setAttribute\('role','tablist'\)/);
  assert.match(appJs, /tab\.setAttribute\('role','tab'\)/);
  assert.match(appJs, /panel\.setAttribute\('role','tabpanel'\)/);
  assert.match(appJs, /panel\.setAttribute\('aria-labelledby'/);
  // one tab stop, then arrow keys — the roving tabindex a tablist requires
  assert.match(appJs, /tab\.tabIndex=active\?0:-1;/);
  assert.match(appJs, /\{ArrowRight:1,ArrowDown:1,ArrowLeft:-1,ArrowUp:-1\}\[event\.key\]/);
  assert.match(appJs, /if\(event\.key==='Home'\)/);
  assert.match(appJs, /if\(event\.key==='End'\)/);
});

test('the chosen tab is remembered for the visit, not for ever', () => {
  // scoped to this helper: an unrelated collapsible elsewhere keeps its own localStorage key
  const body = appJs.slice(appJs.indexOf('function sectionTabsV200'),
    appJs.indexOf('function enhanceBookingsTabsV195'));
  // sessionStorage: a tab is "where was I just now". Restoring last week's choice would hide the
  // section the owner came back for.
  assert.match(body, /sessionStorage\.setItem\(storageKey,groups\[index\]\.name\)/);
  assert.doesNotMatch(body, /localStorage/);
  assert.match(body, /setTab\(initial,\{remember:false\}\)/,
    'restoring a remembered tab must not itself count as a choice');
});

test('a hidden panel can be revealed, so deep links and focus do not fall into a void', () => {
  assert.match(appJs, /function revealSectionTabV200\(node\)/);
  assert.match(appJs, /node\?\.closest\?\.\('\[data-subtab-panel\]'\)/);
  assert.match(appJs, /if\(!panel\|\|!panel\.hidden\)return false;/);
});

test('the strip scrolls rather than wraps', () => {
  // a wrapped pill strip changes height as tabs re-flow, shifting the page under a thumb mid-tap
  assert.match(indexHtml, /\.section-subtabs-v200\{[^}]*overflow-x:auto[^}]*\}/);
  assert.match(indexHtml, /\.section-subtabs-v200 button\{[^}]*white-space:nowrap[^}]*\}/);
  assert.match(indexHtml, /\.section-subtabs-v200\{[^}]*display:flex/);
});
