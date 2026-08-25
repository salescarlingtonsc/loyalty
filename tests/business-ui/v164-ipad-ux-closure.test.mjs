import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const appHtml = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));
const customerUi = readFileSync(resolve(repoRoot, 'app/customer-ui.js'), 'utf8');

test('V164 sidebar terminology is merchant-facing', () => {
  assert.match(customerUi, /star:'m12 3 2\.8 5\.67/);
  assert.match(appHtml, /reports:\['reports','Business Insights'\]/);
  /* V250: the owner made Programmes ONE flat nav link, so the group declares `flat` where it
     declared `label`. The merchant-facing WORD this test guards is unchanged. */
  /* V294: Programmes became a group with Overview/List/History children. The merchant-facing
     WORD this test guards is unchanged. */
  assert.match(appHtml, /\{key:'grow',icon:'star',label:'Rewards & Offer'/);
  /* V170 owner decision: Daily report (today's takings) was fully built and routed but
     absent from every nav group, so owners could not reach it. It now leads the money group. */
  /* V180 owner instruction: Expenses moved ahead of Business Insights (money in, money out,
     result, then why). The merchant-facing terminology this test guards is unchanged. */
  /* V272 owner instruction ("delete this tab cause here have already"): the Staff performance
     entry is gone from this group; the merchant-facing terminology this test guards is unchanged. */
  /* nestly_v517 (owner, photo 9: red crosses through Expenses and P&L, "delete this").
     They leave the NAV only — expensesPage() and pnlPage(), their routes, RPCs and
     FINANCE_MODULES entitlement all survive, so no recorded cost is lost and re-listing
     them is a one-line change. */
  assert.match(appHtml, /\{key:'money',icon:'reports',label:'Reports',items:\['dailyreport','sales','reports','customerintel'\]\}/);
});

test('V164 Dashboard adds schedule glance and in-card KPI action labels', () => {
  assert.match(appHtml, /dashboard-schedule-glance/);
  assert.match(appHtml, /Today schedule/);
  // V252 (owner screenshot): the View bookings button was struck out — it only reached the same
  // appointments surface the Open calendar link already reaches. Open calendar is the survivor.
  assert.doesNotMatch(appHtml, /View bookings/);
  assert.match(appHtml, /Open calendar/);
  assert.match(appHtml, /buttonLabel:'View visits'/);
  assert.match(appHtml, /buttonLabel:'View revenue'/);
  assert.match(appHtml, /buttonLabel:'See new customers'/);
  assert.match(appHtml, /buttonLabel:'See inactive customers'/);
  assert.match(appHtml, /metric-action-label/);
});

test('V164 Dashboard uses clearer collapse persistence and loading labels', () => {
  assert.match(appHtml, /peekaa\.v164\.dashboard\.performance\.open/);
  assert.match(appHtml, /peekaa\.v164\.dashboard\.understand\.open/);
  assert.match(appHtml, /<span class="branch-loading-pill" aria-live="polite">Branch scope<\/span>/);
  /* V225 removed the on-page reporting-scope pickers; the top-bar branch control above is the
     one that remains, and it is asserted on the line before this. */
});

test('V164 merchant insights are concise and remove duplicated revenue CTA', () => {
  assert.match(appHtml, /Revenue has started/);
  assert.match(appHtml, /Sales were recorded this period\. Keep recording activity to unlock a reliable trend\./);
  assert.match(appHtml, /Revenue has started',explanation:'Sales were recorded this period\. Keep recording activity to unlock a reliable trend\.',why:'',actions:\[\]/);
  assert.doesNotMatch(appHtml, /Separate indicators, not a fake score/);
});

test('V164 Reports page is renamed Business Insights and uses visual decision cards', () => {
  assert.match(appHtml, /<h1>Business Insights<\/h1>/);
  assert.match(appHtml, /Visual reports for revenue, bookings, retention and team activity\./);
  /* V294 (owner markup 2026-08-12): the decision cards became a tab bar; the visual grouping
     this test guarded now lives in the four named tabs. */
  assert.match(appHtml, /report-tabbar-v294/);
  assert.match(appHtml, /title:'Sales & Revenue'/);
  assert.match(appHtml, /title:'Efficiency'/);
  assert.match(appHtml, /title:'Customer Retention'/);
  assert.match(appHtml, /title:'Team Performance'/);
});

test('V164 Staff Performance summary cards use concise visual ranking treatment', () => {
  assert.match(appHtml, /Rank staff by revenue, signed commission and sales records for the selected period\./);
  assert.match(appHtml, /staff-rank-card/);
  assert.match(appHtml, /rank-visual/);
  assert.match(appHtml, /Highest attributed revenue/);
  assert.match(appHtml, /Highest signed commission/);
  assert.match(appHtml, /Most revenue-qualified records/);
});

test('V164 Staff Members defaults to a staff-list-first tab structure', () => {
  assert.match(appHtml, /function enhanceStaffMembersTabsV164/);
  assert.match(appHtml, /Staff list/);
  assert.match(appHtml, /Invites &amp; access/);
  assert.match(appHtml, /staff-members-tab-panel/);
  assert.match(appHtml, /staff-members-add-top/);
  assert.match(appHtml, /enhanceStaffMembersTabsV164\(teamPanel\)/);
});

test('V164 Programmes removes persistent setup CTA and keeps categorised overview', () => {
  /* V319 (owner markup 2026-08-14): the module is renamed "Rewards & Offer" — rail group and
     page heading together, per V245's own rule that the two must say the same words. The
     requirement this line protects is that the heading is the MODULE's name, not "Grow". */
  /* V339 (owner markup: "Rewards & Offer" struck out, "Point System" written, on the Points
     System edit screen specifically): the H1 stays "Rewards & Offer" for every OTHER view,
     which this regex now expresses instead of a literal always-static string. */
  /* V340 (owner: "change rewards & offer to rewards programme"): the default arm renamed. */
  /* V341 (owner markup: "move the point system up to the header"): drilled standalone pages
     (points/tiers/offers/history) now carry their OWN name in the H1, not the module's. */
  /* Was a verbatim pin on the whole page-title ternary, so it broke on wording changes and on the
     V366 bring-back route. Evaluate the mapping, which is the property this test is about. */
  const titleExpr = appHtml.match(/<h1 id="growTitle">\$\{([\s\S]*?)\}<\/h1>/)[1];
  const titleFor = view => new Function('programmeView', 'pendingGrowSetupRewardV303',
    'growPointsPageTitleV326', `return (${titleExpr});`)(view, null, 'Point System');
  assert.equal(titleFor('tiers'), 'Tier membership');
  assert.equal(titleFor('bringback'), 'Bring-back rewards');
  assert.equal(titleFor('list'), 'Rewards Programme');
  /* V324 (owner markup 2026-08-14): the subtitle is struck through. The requirement this test
     exists for is the one above — the heading is the MODULE's name, not "Grow" — and it is
     untouched; what went was a second sentence restating that name underneath it. */
  assert.doesNotMatch(appHtml, /Create and manage rewards, promotions and customer programmes\./);
  assert.match(appHtml, /<div class="v150-title-actions"><\/div>/);
  /* V227 (owner: "all points reward in this tab") split "Loyalty & rewards" into two
     categories: Point system holds everything earned and spent in points, Other rewards
     holds the ones that do not use a balance. The behaviour this test protects — that the
     programme rows are categorised rather than one flat list — is unchanged. */
  /* V229 (owner: "square boxes for each topics then press in"; "instead of promotion & growth")
     restructured the overview into topic tiles and renamed the categories in the owner's own
     words. The categorisation these tests protect is unchanged. */
  assert.match(appHtml, /programme-category-title">Point system</);
  /* V358 flattened the Lifestyle rewards grouping into peer tiles by owner ruling. */
  assert.doesNotMatch(appHtml, /programme-category-title">Lifestyle rewards</);
  /* V229: renamed to plain "Promotions" (the owner's word) and Referrals became its own
     category, so both remain distinct from the points work — which is the point here. */
  assert.match(appHtml, /programme-category-title">Promotions</);
  assert.match(appHtml, /programme-category-title">Referrals</);
  /* V229: renamed to say what is in it rather than what it is like. */
  /* V294: gift cards left the category (item 7b) — Memberships stands alone. */
  assert.match(appHtml, /programme-category-title">Memberships</);
  assert.doesNotMatch(appHtml, /<button type="button" class="btn grow-primary" id="growAutoSetup">Continue setup<\/button>/);
});
