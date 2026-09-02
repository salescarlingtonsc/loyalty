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
  /* V468 let a caller pass its own definition (the Daily report's tiles do), so the dialog now
     falls back to the map rather than reading it outright. The scope assertion is unchanged in
     substance: this reader still names the module-scope map, and the caller override cannot
     shadow it. */
  assert.match(app,/const def=options\.def\|\|DASHBOARD_METRIC_DEFINITIONS_V405\[key\]\|\|\{\};/,
    'the dialog still falls back to the module-scope map');
  /* V694: the tile painter's body (the `const def=...` line) moved out of the inline
     metrics.map(...) callback into its own top-level dashboardMetricTileHtmlV405 (so the
     "Peekaa recorded revenue" label fix could be independently vm-executed — see
     tests/business-ui/v694-recorded-revenue-tiles.test.mjs). The call site now hands that
     function the SAME module-scope lookup as an argument instead of destructuring it inline;
     the scope guarantee this test protects — the tile painter reads the module-scope map, not
     a stale function-scoped one — is unchanged. */
  assert.match(app,/metrics\.map\(metric=>dashboardMetricTileHtmlV405\(metric,DASHBOARD_METRIC_DEFINITIONS_V405\[metric\.key\],previousRange\)\)/,
    'the tile painter reads the same module-scope map');
  assert.match(app,/^function dashboardMetricTileHtmlV405\(metric,def,previousRange\)\{/m,
    'the tile painter must be a top-level function, not re-nested inside dashboard()');
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
  /* V407: and it must read the key the RPC actually returns. staff_list_customers_v155 answers
     {customers,total} — there is no `rows` key — so the previous read was silently empty: a
     dialog showing nothing beneath a tile that said 1. Masked until V406, because the invalid
     page size failed first. */
  assert.match(drill,/const rows=Array\.isArray\(data\?\.customers\)\?data\.customers:\[\];/);
  assert.doesNotMatch(drill,/data\?\.rows/,'staff_list_customers_v155 has no rows key');
  assert.match(app,/const cappedV406=rows\.length>=DASHBOARD_INACTIVE_PAGE_V406;/);
  assert.match(app,/if\(cappedV406\)body\.insertAdjacentHTML\('beforeend',/);
});

test('V408 the come-back card does not collapse when its window changes',()=>{
  /* Owner, photo 2: "pressing on the buttons have a very weird move up and down motion".
     renderComebackCardV300 replaced the whole card with a one-line placeholder on EVERY press,
     awaited two RPCs, then rebuilt it — and the card sits above the programme-usage table, so
     the page below flew up and dropped back. A repaint must keep the card and pin its height. */
  assert.match(app,/const repaintV408=host\.querySelector\('\.grow-comeback-card-v401'\);/);
  assert.match(app,/host\.style\.minHeight=`\$\{Math\.round\(host\.getBoundingClientRect\(\)\.height\)\}px`;/);
  assert.match(app,/host\.setAttribute\('aria-busy','true'\);/);
  // The placeholder survives only for the FIRST paint.
  assert.match(app,/\}else\{\s*\n\s*host\.innerHTML=`<div class="card"><p class="muted small">Checking who has come back…<\/p><\/div>`;/);
  // Every exit path releases the pin, or the card would be stuck tall forever.
  const paint=app.slice(app.indexOf('async function renderComebackCardV300('),
                        app.indexOf('async function ',app.indexOf('async function renderComebackCardV300(')+40));
  const releases=[...paint.matchAll(/releaseV408\(\)/g)].length;
  assert.ok(releases>=4,`every exit path must release the height pin, found ${releases}`);
});

test('V408 a KPI drill-down row opens the customer behind it',()=>{
  /* Owner, photo 3: "now that the boxes are clickable — I need to be able to click into the
     individual customer selection". A row with no customer (a walk-in sale) stays inert rather
     than becoming a control that goes nowhere. */
  assert.match(app,/const customerCellV408=\(clientId,label,sub\)=>\{/);
  assert.match(app,/data-metric-client-v408="\$\{esc\(String\(clientId\)\)\}"/);
  assert.match(app,/return clientId\s*\n\s*\? `<button/,'no customer means no control');
  // Delegated once, so every branch's own innerHTML write keeps working.
  assert.match(app,/body\.addEventListener\('click',event=>\{/);
  /* V468: this used to assert a bare `nav(...)` immediately after `close()`. That pairing is the
     history race — activateDialog's teardown pops its entry with an ASYNCHRONOUS history.back(),
     which lands after the synchronous hash write and cancels it, so the row click closed the
     dialog and went nowhere. Both navigating exits now go through dialogHandOffNavV468, so the
     assertion is on the helper, not on the shape that was broken. */
  assert.match(app,/dialogHandOffNavV468\(close,`#\/client\/\$\{hit\.dataset\.metricClientV408\}`\);/);
  assert.doesNotMatch(app,/close\(\);\s*nav\(`#\/client\//,'close() then nav() is the v183 history race');
  /* THREE call sites, not four: visits and revenue share one row builder, so the four tiles are
     served by new / inactive / sales. */
  const drill=app.slice(app.indexOf('async function openDashboardMetricRowsV388('),
                        app.indexOf('function dashboardMetricWasLineV387('));
  assert.equal([...drill.matchAll(/customerCellV408\(/g)].length,3);
});

test('V408 redeeming refreshes the customer standing from the server',()=>{
  /* Owner, photo 1: "when press redeem it must reduce the points immediately". The header figure
     comes from `cust`, captured at lookup; redeeming refetched only the catalogue. The new balance
     is ASKED FOR — subtracting the cost here would be inventing a balance (v145). */
  assert.match(app,/async function refreshTillCustomerStandingV408\(\)\{/);
  assert.match(app,/sb\.rpc\('lookup_client_by_phone',\{p_business:S\.biz\.id,p_phone:lookupPhone\}\)/);
  assert.match(app,/if\(data\?\.status==='found'&&String\(data\.client_id\)===String\(cust\.client_id\)\)cust=data;/,
    'the refreshed row must be the SAME customer, or a re-typed number could swap them mid-sale');
  // Both redemption doors refresh it: the manual one and the QR scan.
  assert.match(app,/await refreshTillCustomerStandingV408\(\);\s*\n\s*draw\(\);/);
  assert.match(app,/onComplete:async\(\)=>\{catalog=null;await refreshTillCustomerStandingV408\(\);draw\(\)\}/);
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
