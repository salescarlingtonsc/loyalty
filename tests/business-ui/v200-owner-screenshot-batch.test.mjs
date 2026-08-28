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
  /* nestly_v584: the slice used to end at enhanceBookingsTabsV195, which no longer exists (owner
     photo 13 deleted the Bookings settings tab). It ends at the next top-level declaration
     instead, which is what "this helper only" always meant. */
  const body = appJs.slice(appJs.indexOf('function sectionTabsV200'),
    appJs.indexOf('let bookingsShellTokenV288', appJs.indexOf('function sectionTabsV200')) > 0
      ? appJs.indexOf('let bookingsShellTokenV288', appJs.indexOf('function sectionTabsV200'))
      : appJs.indexOf('const V183_DAYS=', appJs.indexOf('function sectionTabsV200')));
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

/* ------------------------------------------------- 3b. the modules actually converted */

/* Owner: "convert the remaining modules to tabs". Each conversion below tags real, independent
   sub-modules and leaves everything shared pinned above the strip. Verified in the browser
   against production CSS: every tagged section lands in a panel, nothing is orphaned, and the
   pinned rows stay outside the panels. */

const CONVERSIONS = [
  { key: 'storedvalue', root: 'routeMain', tabs: ['Authority', 'Top-ups', 'Reconciliation', 'Pause &amp; safety', 'Cutover'] },
  /* V468 removed the Customers conversion: the owner struck the "Visit feedback" pill out
     (photo 18) and that queue was one of its only two tabs. One section left means no strip —
     sectionTabsV200 returns null below two groups — so the page no longer opts in at all, and the
     data-subtab tagging that fed it went with it. The ratings themselves survive on each
     customer's own 360 profile. */
  { key: 'giftcards', root: 'routeMain', tabs: ['Issue &amp; redeem', 'Cards on the books'] },
];

for (const { key, root, tabs } of CONVERSIONS) {
  test(`${key} opts in, and every tab it advertises is tagged in its own template`, () => {
    const call = new RegExp(`sectionTabsV200\\(${root.replace(/[$()']/g, '\\$&')},\\{key:'${key}'`);
    assert.match(appJs, call, `${key} must call the helper with the root that owns its sections`);
    for (const label of tabs) {
      assert.ok(appJs.includes(`data-subtab="${label}"`), `${key} is missing a section tagged ${label}`);
    }
  });
}

test('gift cards no longer wraps its sections in the two-column split the tabs replace', () => {
  // a .split wrapper would make the cards grandchildren, and the helper only groups direct
  // children — it would have silently found nothing and rendered no strip at all
  const start = appJs.indexOf("routeMain.innerHTML=`${CUI.pageHeader({title:'Gift cards',subtitle:'Issue and redeem");
  const end = appJs.indexOf("sectionTabsV200(routeMain,{key:'giftcards'", start);
  assert.ok(start > 0 && end > start);
  const template = appJs.slice(start, end);
  assert.doesNotMatch(template, /<div class="split">/);
  assert.match(template, /<div class="card" data-subtab="Issue &amp; redeem">\$\{giftCardWorkspace\}<\/div>/);
});

test('the shared controls each module needs from every tab stay untagged', () => {
  // Customers: the add-customer form opens from the actions bar, so it must not live in a tab
  assert.match(appJs, /<div class="card" id="form" style="display:none;margin-bottom:16px"><\/div>/);
  assert.doesNotMatch(appJs, /id="form"[^>]*data-subtab/);
  // Stored value: the live / not-live banner changes what every other tab MEANS
  assert.doesNotMatch(appJs, /permission-banner[^>]*data-subtab/);
});

/* ------------------------------------------------- V203: the headline removal left a live crash */

/* Removing the V200 headline deleted the `headline` const but left four references to it in the
   dashboard's invalidate and loading paths. Those paths only run on a re-render, so my machine
   never hit them — but every other firm's dashboard died on load with
   "Can't find variable: headline" (Safari) on build 0bfc0d86ee5b.
   `node --check` cannot catch this: an undeclared identifier is a RUNTIME ReferenceError, not a
   syntax error. So this asserts the specific shape rather than pretending to be a linter. */
test('the dashboard renderer references no identifier it does not declare', () => {
  const start = appJs.indexOf('async function dashboard(');
  assert.ok(start > 0, 'the dashboard renderer must exist');
  const next = appJs.indexOf('\nasync function ', start + 10);
  const body = appJs.slice(start, next > 0 ? next : appJs.length);
  // every name the V200 removal deleted must be gone from this scope, declaration AND use
  for (const removed of ['headline', 'dashboardHeadlineHtmlV170', 'dashboardComparisonSentenceV170']) {
    const bare = new RegExp(`(?<![\\w.$])${removed}(?![\\w$])`, 'g');
    assert.equal((body.match(bare) || []).length, 0,
      `the dashboard renderer still references ${removed}, which no longer exists`);
  }
});

test('the identifiers that survived the removal are still declared where they are used', () => {
  // dashboardRangeLabelV170 is still used by the tile hints, so it must still be defined
  assert.match(appJs, /function dashboardRangeLabelV170\(from,to\)/);
  assert.ok((appJs.match(/(?<![\w.$])dashboardRangeLabelV170(?![\w$])/g) || []).length >= 2,
    'a helper that is defined but never used would mean the removal went too far');
});
