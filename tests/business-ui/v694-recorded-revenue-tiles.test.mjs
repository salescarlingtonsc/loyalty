/* NESTLY v694 (check 2 follow-up) — merchant-facing (app/app.js) KPI tiles must never carry a
   bare "Revenue" label on a figure that is Peekaa-recorded sales revenue. This is the app/app.js
   twin of tests/platform-console/v685-recorded-revenue-labels.test.mjs, which already closed the
   same defect for the platform console; the CLAUDE.md check-2 refutation named two more sites:

     app/app.js:21650  DASHBOARD_METRIC_DEFINITIONS_V405.revenue.label — the Home dashboard's
                        revenue KPI tile (rendered by the new top-level dashboardMetricTileHtmlV405,
                        pulled out of the inline kpis.innerHTML=metrics.map(...) template so it is
                        independently executable, same posture as v679's panel renderers).
     app/app.js:51723  DAILY_REPORT_METRIC_DEFINITIONS_V468.revenue.label — the Daily report's
                        revenue KPI tile (rendered by the existing top-level dailyMetricTileV468).

   Both now read 'Peekaa recorded revenue' — the exact canonical phrase app/revenue-truth.js
   already uses verbatim in its `metricCard('Peekaa recorded revenue', ...)` call — not lifted by
   hand here but read back off that file, so this test fails loudly if the canonical wording ever
   changes without this file being updated to match.

   Left deliberately unchanged (bare 'Revenue' stays, with reasons):
     - app/app.js's businessHealthSummaryV153 ('Revenue' / 'Improving' / '+12% vs previous period')
       is a TREND status row, not a figure tile — no dollar amount is printed next to the word, so
       there is no bare number a merchant could mistake for total business revenue.
     - Table column headers ('Revenue' above per-row or per-category money cells in the customer
       drilldown, category-mix, demographics and weekday-behaviour tables) are column labels over
       itemised or per-segment rows the merchant is already looking at broken down, not a headline
       claim of "this is the business's revenue" the way a dashboard/report KPI tile is. They are
       out of scope for this check the same way v685's own guard scoped out the platform overview's
       explicitly-labelled "Revenue: Projection only" line.
     - Package/gift-card cash-collected figures (DAILY_REPORT_METRIC_DEFINITIONS_V468.giftcards,
       sell_package's revenue-upfront figures) are deliberately NOT relabelled: they have their own
       "cash collected, not revenue" semantics (nestly_v9/v10) and calling them "recorded revenue"
       would be wrong in the other direction. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const revenueTruthSrc = readFileSync(join(root, 'app', 'revenue-truth.js'), 'utf8');

const canonicalMatch = revenueTruthSrc.match(/metricCard\('([^']+)'/);
assert.ok(canonicalMatch, 'app/revenue-truth.js must define the canonical recorded-revenue label via metricCard(...)');
const CANONICAL_LABEL = canonicalMatch[1];
assert.equal(CANONICAL_LABEL, 'Peekaa recorded revenue');

function esc(x) {
  return String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* --- Surface 1: dashboardMetricTileHtmlV405 (Home dashboard KPI tile) --- */

const chipStart = app.indexOf('function dashboardDeltaChipV170(');
const chipEnd = app.indexOf('function helpDotMarkupV385(', chipStart);
assert.ok(chipStart > -1 && chipEnd > chipStart, 'dashboardDeltaChipV170 must be a top-level function');
const chipBlock = app.slice(chipStart, chipEnd);

const defsStart = app.indexOf('const DASHBOARD_METRIC_DEFINITIONS_V405={');
const defsEnd = app.indexOf('};', defsStart) + 2;
assert.ok(defsStart > -1 && defsEnd > defsStart + 2, 'DASHBOARD_METRIC_DEFINITIONS_V405 must exist');
const defsBlock = app.slice(defsStart, defsEnd);

const tileStart = app.indexOf('function dashboardMetricWasLineV387(');
const tileEnd = app.indexOf('function dashboardDeltaLegendV385(', tileStart);
assert.ok(tileStart > -1 && tileEnd > tileStart, 'dashboardMetricWasLineV387/dashboardMetricTileHtmlV405 must be top-level functions');
const tileBlock = app.slice(tileStart, tileEnd);

assert.match(tileBlock, /function dashboardMetricTileHtmlV405\(metric,def,previousRange\)\{/,
  'the dashboard KPI tile renderer must be a standalone, independently-testable top-level function');

function renderDashboardTile(key, metric) {
  const sandbox = {
    esc,
    workspaceTemplateAttributeV97: (attribute, keyName, values) => `${attribute}="${esc(JSON.stringify(values))}"`
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${chipBlock}\n${defsBlock}\n${tileBlock}\n__exports.render=dashboardMetricTileHtmlV405;__exports.defs=DASHBOARD_METRIC_DEFINITIONS_V405;`,
    context
  );
  const def = context.__exports.defs[key];
  return context.__exports.render(metric, def, { previousFrom: null, previousTo: null, days: 0 });
}

test('V694 dashboard revenue KPI tile: carries the exact canonical label, not a bare "Revenue"', () => {
  const html = renderDashboardTile('revenue', { key: 'revenue', value: 'SGD 4560.00', hint: '', delta: null, was: null });
  assert.ok(html.includes(CANONICAL_LABEL), `dashboard revenue tile must label its figure "${CANONICAL_LABEL}"`);
  assert.doesNotMatch(html, /<span class="l">Revenue<\/span>/, 'dashboard revenue tile must not print a bare "Revenue" KPI label');
  assert.ok(html.includes('SGD 4560.00'), 'the real figure must still render unchanged');
});

test('V694 dashboard visits tile is untouched: still a bare label (it is a count, not a revenue figure)', () => {
  const html = renderDashboardTile('visits', { key: 'visits', value: '12', hint: '', delta: null, was: null });
  assert.ok(html.includes('>Valid visits<'), 'visits tile keeps its own label, unrelated to the revenue fix');
});

/* --- Surface 2: dailyMetricTileV468 (Daily report KPI tile) --- */

const dailyDefsStart = app.indexOf('const DAILY_REPORT_METRIC_DEFINITIONS_V468={');
const dailyTileStart = app.indexOf('function dailyMetricTileV468(');
const dailyTileEnd = app.indexOf('async function dailyReportPage(', dailyTileStart);
assert.ok(dailyDefsStart > -1 && dailyTileStart > dailyDefsStart && dailyTileEnd > dailyTileStart,
  'DAILY_REPORT_METRIC_DEFINITIONS_V468 and dailyMetricTileV468 must both be top-level');
const dailyBlock = app.slice(dailyDefsStart, dailyTileEnd);

function renderDailyTile(key, value) {
  const sandbox = { esc };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(`${dailyBlock}\n__exports.render=dailyMetricTileV468;`, context);
  return context.__exports.render(key, value);
}

test('V694 daily report revenue KPI tile: carries the exact canonical label, not a bare "Revenue"', () => {
  const html = renderDailyTile('revenue', 'SGD 890.00');
  assert.ok(html.includes(CANONICAL_LABEL), `daily report revenue tile must label its figure "${CANONICAL_LABEL}"`);
  assert.doesNotMatch(html, /<span class="l">Revenue<\/span>/, 'daily report revenue tile must not print a bare "Revenue" KPI label');
  assert.ok(html.includes('SGD 890.00'), 'the real figure must still render unchanged');
});

test('V694 daily report gift-card tile is deliberately untouched (cash collected, not revenue)', () => {
  const html = renderDailyTile('giftcards', 'SGD 200.00');
  assert.ok(html.includes('Gift-card issuance amount recorded'),
    'gift-card figure keeps its own cash-collected semantics, distinct from recorded revenue');
});

/* --- Whole-file sweep: no remaining `label:'Revenue'` in app/app.js outside this file's named
   allowlist. The allowlist is empty — both known sites were fixed above — so this is effectively
   "never again", but is written as an allowlist (rather than a flat assert-false) so a future,
   genuinely-different bare-Revenue label can be added deliberately with its own justification,
   the same shape as v685's own whole-block guard for platform-console.js. */
test('V694 CONTRACT: no `label:\'Revenue\'` KPI-tile entry remains anywhere in app/app.js', () => {
  const ALLOWLISTED_LINES = []; // none — both v694 sites were fixed, not allowlisted
  const matches = [...app.matchAll(/label:'Revenue'/g)];
  const survivors = matches.filter(m => {
    const line = app.slice(0, m.index).split('\n').length;
    return !ALLOWLISTED_LINES.includes(line);
  });
  assert.deepEqual(survivors.map(m => app.slice(0, m.index).split('\n').length), [],
    'every merchant-facing KPI-tile revenue label must read "Peekaa recorded revenue", never bare "Revenue"');
});
