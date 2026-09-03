import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=(fs.readFileSync(path.join(repo,'app/index.html'),'utf8')+'\n'+fs.readFileSync(path.join(repo,'app/app.js'),'utf8'));

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}

const dashboard=section('async function dashboard(){','/* ---------- customers ---------- */');
/* V405: the metric definitions map moved OUT of dashboard() to module scope, because
   openDashboardMetricRowsV388 is a top-level function and could not see it there — every KPI
   tile click since v388 threw a silent ReferenceError. Assertions about the map's CONTENT read
   the module-scope block; assertions about the dashboard's own markup still read dashboard(). */
const metricDefs=section('const DASHBOARD_METRIC_DEFINITIONS_V405={','async function openDashboardMetricRowsV388(');
/* V694: the KPI tile's own markup (data-dashboard-metric, the aria-label template call) moved OUT
   of dashboard() into its own top-level dashboardMetricTileHtmlV405 — pulled out so the label fix
   for check 2 ("Peekaa recorded revenue", not a bare "Revenue") could be independently vm-executed
   and tested (tests/business-ui/v694-recorded-revenue-tiles.test.mjs), the same posture v679's
   panel renderers already use. Same precedent as the V405 comment above: assertions about the
   tile's own markup now read tilePainter; dashboard() still calls it via metrics.map(...). */
const tilePainter=section('function dashboardMetricTileHtmlV405(metric,def,previousRange){','function dashboardDeltaLegendV385(');
const customers=section('async function clientsPage(){','async function clientDetail(id){');
const profile=section('async function clientDetail(id){','/* ---------- quick earn (');

test('V141 dashboard removes duplicate launchers and keeps branch-scoped performance visible',()=>{
  assert.match(app,/flat:'Dashboard',items:\['dashboard'\]/);
  assert.doesNotMatch(dashboard,/taskLauncher|task-launcher-grid|<details class="card performance-panel"/);
  /* V225: the owner struck the per-page reporting-scope picker off the Dashboard and
     Customers. The top bar carries one "Viewing" control for the whole workspace, and a
     second on-page picker contradicted it as often as it agreed. The scope still applies —
     currentReportingScopePayloadV155 now derives it from that single control. */
  assert.doesNotMatch(dashboard,/id="dashboardReportingScopeWrap"/);
  assert.match(app,/const mode=followsTopBar\?\(selectedBranchId\?'current':'all'\):'selected';/);
  assert.match(dashboard,/data-d="1"[^>]*>Today</);
  assert.match(dashboard,/class="performance-heading ux154-collapsible-head"[\s\S]*CUI\.icon\('reports'/);
  assert.doesNotMatch(dashboard,/performance-panel>summary|<summary>Performance/);
});

test('V141/V150 every visible KPI is a semantic drilldown with plain definitions',()=>{
  for(const key of ['visits','revenue','new','inactive']){
    assert.match(metricDefs,new RegExp(`${key}:\\{label:`));
    assert.match(dashboard,new RegExp(`key:'${key}'`));
  }
  for(const removedKey of ['unique','points','credit']){
    assert.doesNotMatch(dashboard,new RegExp(`key:'${removedKey}'`));
  }
  assert.match(tilePainter,/data-dashboard-metric="\$\{metric\.key\}"/);
  assert.match(metricDefs,/Customer membership or customer records created during the selected period/);
  /* V287 retarget: the definition used to claim "at least 30 days" while the tile drilled
     through to the 30-59 bucket only. The number and the destination must describe the same
     group, and the definition must say so.
     V290 retarget: that rule is unchanged, but the group is no longer narrowed. V290 added the
     'all_inactive' bucket to staff_list_customers_v155, so the destination V287 could not express
     exists and the tile counts every customer quiet for 30 days or more again. */
  assert.match(metricDefs,/Customers whose last valid visit was 30 or more complete Singapore days ago/);
  assert.match(dashboard,/p_inactive_bucket:'all_inactive'/);
  /* V287 retarget: openDashboardMetricDetailV141 was unreachable after V225 made every tile a
     direct link (all four definitions carry a route, so the `else` could never run). The
     drilldown contract this test guards is now the navigation itself. */
  assert.doesNotMatch(dashboard,/function openDashboardMetricDetailV141\(/);
  /* V388 (owner, photo 1: "it should really allow see new customers pop up"). The tile opens the
     ROWS behind the figure now instead of jumping straight to a report. Every definition still
     carries its route — the dialog hands off to it at the foot — so the drilldown contract this
     test guards is intact; only what the first press does changed. */
  assert.match(dashboard,/openDashboardMetricRowsV388\(\{key,from,to,scopePayload,/);
  /* V470 (owner, four photos: "remove this button" on the dialog's footer link). V388 built this
     dialog as a preview that handed off to a report at its foot; V408 then made every ROW open its
     customer directly, leaving the footer a second and worse way to the same place — and the one
     the owner kept pressing. The footer is gone, and with it the `route` key on every definition,
     which nothing read any more. The rows ARE the destination now. */
  assert.doesNotMatch(app,/metricRowsGoV388/,'the footer link is gone, not merely hidden');
  assert.doesNotMatch(metricDefs,/route:/,'a route nothing navigates to is stale data');
  /* V388: the hand-off to the report moved into the dialog's own footer control.
     V468 (owner photos 3, 8 and 9 — "View visits" / "See new customers" / "See inactive
     customers" all did nothing): this assertion used to pin `close();nav(def.route)`, which is
     precisely the defect. activateDialog's teardown pops its history entry with an ASYNCHRONOUS
     history.back(); the pop lands after the synchronous hash write and cancels it, so the dialog
     closed and the page never moved. Both navigating exits now go through dialogHandOffNavV468,
     the same hand-off wireCustomerSheetNavV183 has used since v183. */
  /* What the V468 fix protected still holds and still matters, on the row exit that remains:
     activateDialog's teardown pops its history entry with an ASYNCHRONOUS history.back(), which
     would otherwise land after the hash write and cancel it. */
  assert.match(app,/dialogHandOffNavV468\(close,`#\/client\//,
    'the row exit still hands off its history entry');
  assert.doesNotMatch(app,/close\(\);nav\(/,'close() then nav() is the v183 history race');
  assert.match(tilePainter,/workspaceTemplateAttributeV97\('aria-label','viewDashboardMetricDetails'/);
  assert.match(dashboard,/appliedDashboardScopeV141/);
  assert.match(metricDefs,/business-current/); // V405: scope tag lives in the module-scope map
});

test('V141 charts communicate reconciled intensity, SGD and demographics while unsafe gross sale mix stays hidden',()=>{
  assert.match(dashboard,/dashboardWeekdayColoursV141/);
  assert.match(dashboard,/quiet/);
  assert.match(dashboard,/medium/);
  assert.match(dashboard,/busiest/);
  assert.match(dashboard,/Recorded gender/);
  assert.match(dashboard,/gender_counts/);
  assert.doesNotMatch(dashboard,/Services and goods sold|dashboardSaleMixV141|sale_items/);
  assert.match(dashboard,/ticks:\{callback:[^}]*SGD/);
  assert.match(dashboard,/CUI\.icon\('reports'/);
});

test('V141 dashboard load failures stay in context and can be retried',()=>{
  assert.match(dashboard,/id="dashboardStatus" aria-live="polite"/);
  assert.match(dashboard,/Performance data could not be loaded\./);
  assert.match(dashboard,/dashboardReportRetry/);
  /* V288: one banner now covers BOTH inactive reads (30-59 and 60+), so the copy is plural. */
  assert.match(dashboard,/Inactive customer counts could not be loaded\./);
  assert.match(dashboard,/dashboardInactiveRetry/);
  assert.doesNotMatch(dashboard,/Services and goods detail could not be loaded\./);
});

test('V141 core dashboard copy is localized in Chinese and Malay',()=>{
  for(const label of ['Visit entries','Revenue','Unique customers','New customers','Points issued','Credit liability','Busiest days','Performance data could not be loaded.','All business customers','All permitted branches','Current balance/status']){
    const occurrences=app.split(`'${label}':`).length-1;
    assert.ok(occurrences>=2,`${label} must appear in both workspace dictionaries`);
  }
  /* V287 retarget: the only call sites for these three were inside
     openDashboardMetricDetailV141, the metric modal V225 made unreachable and V287 deleted.
     Nothing localized was lost — no user could open that dialog. The dictionary coverage
     asserted above is kept so the phrases stay translated if a surface reuses them. */
  assert.doesNotMatch(dashboard,/function openDashboardMetricDetailV141\(/);
  assert.match(tilePainter,/workspaceTemplateAttributeV97\('aria-label','viewDashboardMetricDetails'/);
});

test('V141 customer directory exposes last-visit choice and date joined',()=>{
  assert.match(customers,/Show customers by last visit/);
  /* The customer directory must read through a tenant-scoped, versioned RPC rather than a raw
     table query. The VERSION deliberately is not pinned: this reader has moved v129 -> v154 ->
     v155 and each bump broke this assertion without anything actually regressing. What matters
     is the shape, so that is what is asserted. */
  assert.match(customers,/sb\.rpc\('staff_list_customers_v\d+'/);
  assert.match(customers,/formatCustomerJoinedDateV141\(c\.created_at\)/);
  assert.match(customers,/Date joined/);
  assert.match(customers,/formatCustomerJoinedDateV141/);
  assert.match(customers,/Never visited/);
});

/* V249: the owner struck out the "Peekaa's suggestion" banner entirely; the expiry note and the
   icon-led rewards card this test also protects are unchanged. */
test("V141 customer profile presents the points expiry note and an icon-led rewards card",()=>{
  assert.doesNotMatch(profile,/Peekaa(?:&apos;|')s suggestion/);
  assert.match(profile,/c360-points-expiry/);
  assert.match(profile,/nextExp\.remaining/);
  assert.match(profile,/staff_get_customer_actionable_loyalty_v145/);
  assert.match(profile,/const nextExp=loyaltyFacts\?\.expiry/);
  assert.match(profile,/Loyalty balances and reward availability are temporarily unavailable/);
  assert.match(profile,/c360LoyaltyRetry/);
  assert.match(profile,/class="c360-rewards-head"/);
  assert.match(profile,/CUI\.icon\('loyalty'/);
  assert.match(profile,/id="c360-loyalty"/);
});
