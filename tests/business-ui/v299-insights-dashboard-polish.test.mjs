/* V299 Business Insights / Dashboard presentation polish — regressions.
 *
 * Each assertion fails against the pre-V299 source:
 *  1. `.metric` and `.report-scope-card` finally have CSS — every Insights tab's headline
 *     number rendered at body size directly beneath the 1.85rem V297 verdict value.
 *  2. The Dashboard delta chip speaks the same three-tone language as Insights: a fall is
 *     the red `no` pill, not the same grey `off` pill a flat 0% gets.
 *  3. The V297 cards no longer restate the previous-period figure the verdict band one line
 *     above them already states (the exact duplication V200 removed from the Dashboard).
 *  4. The report share-bar palette reads from :root --chart-* tokens instead of six literals,
 *     and the bring-back playbook reuses the same bar component instead of a third hand-rolled
 *     idiom, with its headline in ink rather than the disabled grey.
 *  5. The Dashboard KPI grid follows its tile count (2 or 3 tiles no longer float in a fixed
 *     4-column row). V399 changed the mechanism from auto-fit to --kpi-count; see the test.
 *  6. Business Insights has quick date-range presets (7/30/90 days, 6/12 months) that fill the
 *     SAME From/To pair and press the same Run — no new computation path.
 *  7. Customer 360 states Member since from the already-fetched client row; the dead
 *     '30_59' inactivity assignment (overwritten on the next line since V290) is gone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('.metric and .report-scope-card have real rules',()=>{
  assert.match(indexHtml,/\.metric\{font-size:1\.6rem;font-weight:750/);
  assert.match(indexHtml,/@media\(max-width:720px\)\{\.metric\{font-size:22px\}\}/);
  assert.match(indexHtml,/\.report-scope-card\{padding:16px 18px\}/);
  assert.match(indexHtml,/\.report-scope-card \.range input\[type=date\]\{width:auto;min-width:150px\}/);
});

test('dashboard delta chip gains the down tone',()=>{
  assert.match(app,/metric-delta pill \$\{change>0\?'ok':change<0\?'no':'off'\}/);
});

test('V297 cards do not restate the previous-period figure under their own verdict band',()=>{
  assert.doesNotMatch(app,/booked hours in the previous \$\{scope\.days\}-day period/);
  assert.doesNotMatch(app,/\$\{previousReturning\} in the previous \$\{scope\.days\}-day period/);
});

test('share-bar palette reads from tokens and the playbook reuses the shared bar',()=>{
  assert.match(indexHtml,/--chart-1:#C24135; --chart-2:#1F6B48; --chart-3:#1F5199; --chart-4:#8A5A12; --chart-5:#7A2E9D; --chart-6:#6B6673;/);
  assert.match(app,/const REPORT_SHARE_COLOURS_V297=\['var\(--chart-1\)','var\(--chart-2\)','var\(--chart-3\)','var\(--chart-4\)','var\(--chart-5\)','var\(--chart-6\)'\]/);
  assert.match(app,/<div class="report-share-bar-v297" style="margin-top:4px"><span style="width:\$\{Math\.max\(value\/scale\*100,value>0\?4:0\)\}%;background:\$\{colour\}"><\/span><\/div>/);
  assert.doesNotMatch(app,/height:12px;border-radius:6px;background:var\(--line\);overflow:hidden;margin-top:3px/);
  assert.match(app,/return `<div class="metric">\$\{esc\(headline\)\}<\/div>/);
  assert.doesNotMatch(app,/font-size:1\.7rem;font-weight:700;color:var\(--muted\)/);
});

test('dashboard KPI grid follows the tile count, never a fixed 4-column row',()=>{
  /* V299 replaced a hardcoded repeat(4,...) with auto-fit so 2 or 3 tiles would not float in a
     rigid four-column row. V399 keeps that requirement and changes only the mechanism, because
     auto-fit could not actually deliver it: the delta legend inside #kpis is a grid-column:1/-1
     item, and auto-fit only collapses tracks NOTHING occupies, so the spanning legend held every
     track open. Measured in Chromium at 1440px: five tracks for four tiles, the row ending 211px
     short of the card edge — the emptiness in the owner's photo 6.
     --kpi-count is the number of tiles that actually rendered, so 2 tiles give 2 columns and 4
     give 4, all filling the row. The original prohibition stands. */
  assert.match(indexHtml,/\.dashboard-kpis\.v150-dashboard-kpis\{grid-template-columns:repeat\(var\(--kpi-count,4\),minmax\(0,1fr\)\)\}/);
  assert.doesNotMatch(indexHtml,/\.dashboard-kpis\.v150-dashboard-kpis\{grid-template-columns:repeat\(4,minmax\(150px,1fr\)\)\}/);
  // The count must be published from the painter, or the custom property is a dead default.
  assert.match(app,/kpis\.style\.setProperty\('--kpi-count',String\(Math\.max\(1,metrics\.length\)\)\);/);
});

test('V405 the KPI drill-down can actually see its own definitions map',()=>{
  /* Reproduced in production 2026-08-21: every KPI tile click since v388 threw
     `ReferenceError: dashboardMetricDefinitionsV141 is not defined` and did nothing visible.
     openDashboardMetricRowsV388 is a TOP-LEVEL function; the map it reads was declared with
     `const` INSIDE dashboard(). Both the undeclared-identifier scan and `node --check` pass on
     that shape, because the name IS declared — just somewhere the reader cannot reach — and the
     throw surfaces as an unhandled promise rejection, which is silent.
     So the assertion has to be about SCOPE, not existence: the map is declared at column 0, and
     the two readers name it. */
  assert.match(app,/^const DASHBOARD_METRIC_DEFINITIONS_V405=\{/m,
    'the metric definitions map must live at module scope, not inside dashboard()');
  assert.doesNotMatch(app,/^\s+const DASHBOARD_METRIC_DEFINITIONS_V405=/m,
    'an indented declaration means it has been pushed back inside a function');
  assert.match(app,/^async function openDashboardMetricRowsV388\(/m,
    'the drill-down is top-level, which is why the map must be too');
  assert.match(app,/const def=DASHBOARD_METRIC_DEFINITIONS_V405\[key\]\|\|\{\};/,
    'the dialog reads the module-scope map');
  assert.match(app,/const def=DASHBOARD_METRIC_DEFINITIONS_V405\[metric\.key\];/,
    'the tile painter reads the same module-scope map');
  // Nothing may reference the old function-scoped name outside a comment.
  const live=app.split('\n').filter(line=>line.includes('dashboardMetricDefinitionsV141')
    && !/^\s*(\*|\/\*|\/\/)/.test(line));
  assert.deepEqual(live,[],'the function-scoped name must be gone from live code');
});

test('V406 the Inactive drill-down asks for a page size the server accepts',()=>{
  /* Reproduced in production once V405 let the dialog open: the Inactive tile's dialog rendered
     only "limit must be between 1 and 100". It asked staff_list_customers_v155 for p_limit:200,
     which that function refuses outright — so this branch had never returned a row. The other
     three tiles read `sales` directly and were never subject to that bound, which is why only
     this one was broken.
     100 is the SERVER's ceiling, named once so the request and the "showing the first N" line
     cannot drift apart. */
  assert.match(app,/^const DASHBOARD_INACTIVE_PAGE_V406=100;$/m);
  /* Scoped to the DRILL-DOWN. The tile's own count query calls the same RPC with p_limit:1 —
     it wants the total, not the rows — and that is correct, so a file-wide ban would be wrong. */
  const drill=app.slice(app.indexOf('async function openDashboardMetricRowsV388('),
                        app.indexOf('function dashboardMetricWasLineV387('));
  assert.ok(drill.length>500,'the drill-down slice must be found');
  assert.match(drill,/p_inactive_bucket:'all_inactive',p_limit:DASHBOARD_INACTIVE_PAGE_V406,/);
  assert.doesNotMatch(drill,/p_limit:\d+/,
    'the inactive drill-down must not hardcode a page size the server may reject');
  // V287's rule: the number and the list must describe the same people, or the gap must be stated.
  assert.match(app,/const cappedV406=rows\.length>=DASHBOARD_INACTIVE_PAGE_V406;/);
  assert.match(app,/if\(cappedV406\)body\.insertAdjacentHTML\('beforeend',/);
});

test('Business Insights carries quick-range presets that press the existing Run',()=>{
  assert.match(app,/\[\[7,'7 days'\],\[30,'30 days'\],\[90,'90 days'\],\[182,'6 months'\],\[365,'12 months'\]\]/);
  assert.match(app,/data-report-preset-days="\$\{presetDays\}"/);
  assert.match(app,/\$\('rf'\)\.value=shiftSgDateInput\(today,-\(presetDays-1\)\);/);
  assert.match(app,/data-report-preset-days[\s\S]{0,400}?\$\('rgo'\)\.click\(\);/);
  assert.match(indexHtml,/\.report-scope-presets\{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px\}/);
});

test('customer 360 states Member since from the fetched row',()=>{
  assert.match(app,/select\('id,business_id,full_name,phone,email,referral_code,marketing_consent,created_at'\)/);
  assert.match(app,/c\.created_at\?summaryRowV294\('Member since',`<b>\$\{esc\(formatCustomerJoinedDateV141\(c\.created_at\)\)\}<\/b>`\):''/);
});
