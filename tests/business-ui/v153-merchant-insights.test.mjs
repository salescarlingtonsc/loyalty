import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const rules = readFileSync(new URL('../../docs/insights/V153-MERCHANT-INSIGHTS-RULES.md', import.meta.url), 'utf8');
const readiness = readFileSync(new URL('../../docs/insights/V153-MULTI-BRANCH-READINESS.md', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

const dashboard = section('async function dashboard()', 'async function clientsPage()');
const customers = section('async function clientsPage()', 'async function clientDetail');
const helpers = section('const MIN_INSIGHT_REVENUE_CHANGE_PCT_V153', 'async function clientsPage()');

test('V153 dashboard renders Merchant Insights from current and previous equivalent periods', () => {
  assert.match(dashboard, /id="dashboardInsights"/);
  assert.match(dashboard, /previousEquivalentRangeV153\(from,to\)/);
  assert.match(dashboard, /previousRange\.previousFrom/);
  assert.match(dashboard, /previousRange\.previousTo/);
  assert.match(dashboard, /get_dashboard_summary/);
  assert.match(dashboard, /buildMerchantInsightsV153/);
  assert.match(app, /Merchant insights/);
});

test('V153 deterministic insight rules guard zero-base percentages and minimum thresholds', () => {
  assert.match(helpers, /MIN_INSIGHT_REVENUE_CHANGE_PCT_V153=10/);
  assert.match(helpers, /if\(previousNumber<=0\)return null/);
  assert.match(helpers, /Revenue has started/);
  assert.match(helpers, /MIN_INSIGHT_BUSIEST_VISITS_V153=2/);
  assert.match(helpers, /No valid visit for 60 to 89 complete Singapore days/);
  assert.match(rules, /Zero-base behaviour/);
  assert.match(rules, /previous period revenue must be greater than zero/);
  assert.match(rules, /at least two valid visits/);
});

test('V153/V154 retention audiences use mutually exclusive groups and preparation-only campaign UX', () => {
  assert.match(customers, /clientAudienceActions/);
  assert.match(customers, /classifyInactiveCustomersV153/);
  assert.match(helpers, /'30_59'/);
  assert.match(helpers, /days>=30&&days<=59/);
  assert.match(helpers, /days>=60&&days<=89/);
  assert.match(helpers, /never\|\|days>=90/);
  assert.match(app, /Campaign delivery is not enabled yet/);
  assert.match(app, /Save draft/);
  assert.doesNotMatch(section('function openCampaignPrepV153', 'function insightCardV153'), />Send</);
});

test('V153 campaign audience preview avoids fabricated notification reachability', () => {
  assert.match(app, /Notification-device eligibility is not enabled yet/);
  assert.match(app, /Push notifications are available only for eligible customers who have installed Peekaa and enabled notifications/);
  assert.match(rules, /It intentionally has no `Send` action/);
  assert.match(rules, /No live notification delivery or WhatsApp sending is added/);
});

test('V153/V154 presents business health as separate indicators rather than a subjective score', () => {
  assert.match(app, /Business health/);
  assert.match(app, /More data needed/);
  assert.match(rules, /V153 does not create a numeric Business Health Score/);
  assert.match(rules, /Revenue trend: improving, stable, needs attention, or not enough data/);
  assert.match(rules, /Visit activity: improving, stable, needs attention, or not enough data/);
});

test('V153 multi-branch readiness does not certify unsupported selected-branch or branch-promotion capabilities', () => {
  assert.match(readiness, /58 \/ 100/);
  assert.match(readiness, /Selected multiple-branch Dashboard \| Not supported/);
  assert.match(readiness, /Promotions one branch \| Not supported/);
  assert.match(readiness, /Promotions multiple branches \| Not supported/);
  assert.match(readiness, /Server-side branch enforcement is a release blocker/);
  assert.match(readiness, /Current Dashboard and Reports APIs accept one branch UUID or null/);
});

test('V153 explicitly preserves protected business semantics', () => {
  const safety = /does not change financial, loyalty, ledger, reversal, credit, package,\s+expense, P&L, appointment, billing, authentication, tenant or permission\s+semantics/;
  assert.match(rules, safety);
  assert.match(readiness, /does not alter any financial,\s+loyalty, ledger, reversal, expense, P&L, appointment, billing, authentication,\s+tenant or permission semantics/);
});
