/* V550 — the recovered-revenue report ("Peekaa brought back N customers and recovered $X").
   Strategy ruling 2026-08-26: the moat metric is a CONSERVATIVE, auditable number. Every
   judgement (lapsed guard, 30-day attribution, baseline, net scaling) lives in
   get_recovery_report_v550; the renderer is a pure top-level function these tests EXECUTE
   against fixture payloads shaped exactly like the deployed RPC's output. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260827_nestly_v550_recovery_report.sql'), 'utf8');

const blockStart = app.indexOf('function recoveryReportHtmlV550(');
const blockEnd = app.indexOf('async function reportsPage(){', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart, 'the renderer must be a top-level function before reportsPage');
const block = app.slice(blockStart, blockEnd);

function render(data) {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    CUI: { emptyState: ({ title, body }) => `<div class="empty"><b>${title}</b><p>${body}</p></div>`, icon: () => '' }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(block + '\n__exports.render = recoveryReportHtmlV550;', context);
  return context.__exports.render(data);
}

/* The exact shape (and numbers) proven by db/tests/v550_recovery_report.sql:
   treated 4 (2 vouchers + 2 messages), returned 3, gross 10000, baseline 2/1, net 3333. */
const FIXTURE = {
  window: { from: '2026-07-12', to_exclusive: '2026-08-27', attribution_days: 30, min_absence_days: 14 },
  interventions: { treated: 4, vouchers: 2, messages: 2, excluded_not_lapsed: 1 },
  returned: { count: 3, rate_pct: 75.0 },
  recovered: { gross_cents: 10000, redeemed_vouchers: 1, redeemed_voucher_cents: 3000 },
  baseline: { cohort: 2, returned: 1, rate_pct: 50.0 },
  net: { cents: 3333, method: 'gross scaled by (1 - baseline_rate / treated_rate), floored at zero' },
  low_confidence: true,
  monthly: [{ month: '2026-07', interventions: 4, returned: 3, gross_cents: 10000 }]
};

test('V550 the report prints the server verdict: net, gross, funnel, baseline, method', () => {
  const html = render(FIXTURE);
  assert.ok(html.includes('Recovered revenue (estimated)'));
  assert.ok(html.includes('SGD 33.33'), 'the net figure is the server number, never recomputed');
  assert.ok(html.includes('SGD 100.00'), 'gross appears beside net, never instead of it');
  assert.ok(html.includes('gross scaled by (1 - baseline_rate / treated_rate)'), 'the method is stated on the page');
  assert.ok(html.includes('>4</b>') && html.includes('(75.0%)'), 'funnel counts and rate come through');
  assert.ok(html.includes('1 contact was excluded'), 'the not-lapsed exclusion is announced, not absorbed');
  assert.ok(html.includes('<b>2</b>') && html.includes('(50.0%)'), 'the baseline cohort and its rate are visible');
  assert.ok(html.includes('SGD 30.00'), 'the redeemed voucher value is shown');
  assert.ok(html.includes('2026-07'), 'the monthly table renders');
  assert.ok(html.includes('Whole business, all branches'), 'the business-wide scope is stated');
});

test('V550 small numbers raise the low-confidence banner; solid numbers do not', () => {
  assert.ok(render(FIXTURE).includes('Small numbers, read with care'));
  const solid = JSON.parse(JSON.stringify(FIXTURE));
  solid.low_confidence = false;
  assert.ok(!render(solid).includes('Small numbers, read with care'));
});

test('V550 a period with no activity explains how recovery happens instead of showing zeros', () => {
  const html = render({
    window: { attribution_days: 30 },
    interventions: { treated: 0, vouchers: 0, messages: 0, excluded_not_lapsed: 0 },
    returned: { count: 0, rate_pct: null },
    recovered: { gross_cents: 0, redeemed_vouchers: 0, redeemed_voucher_cents: 0 },
    baseline: { cohort: 5, returned: 1, rate_pct: 20 },
    net: { cents: 0 }, low_confidence: true, monthly: []
  });
  assert.ok(html.includes('No bring-back activity in this period'));
  assert.ok(html.includes('Message buttons') && html.includes('Bring-back'), 'both intervention sources are named');
  assert.ok(!html.includes('Recovered revenue (estimated)'), 'no zero-stuffed report is rendered');
});

test('V550 a malformed payload renders the empty state, not a crash', () => {
  assert.ok(render(null).includes('No bring-back activity'));
  assert.ok(render({}).includes('No bring-back activity'));
});

/* ---------------------------------------------------------------- wiring + server authority */

test('V550 the Reports page hosts the tab, runner, gate and invalidation', () => {
  assert.ok(app.includes("{key:'recovered',bodyId:'recoveredBody',panelId:'reportPanelRecoveredV550'"),
    'the tab is declared beside its siblings');
  assert.ok(app.includes('recovered:runRecovered'), 'the runner is registered');
  assert.ok(app.includes('recoveredGate.invalidate()'), 'a range change invalidates the report');
  assert.ok(app.includes("['recoveredBody','Recovered-revenue']"), 'invalidation resets the panel body');
  assert.ok(app.includes("sb.rpc('get_recovery_report_v550',{p_business:S.biz.id,p_from:scope.from,p_to:shiftSgDateInput(scope.to,1)})"),
    'the runner passes the page range with the exclusive-to convention');
});

test('V550 the browser never re-derives the attribution judgement', () => {
  assert.ok(!/baseline_rate\s*\/\s*treated_rate/.test(block.replace(/gross scaled by[^']*'/, '')),
    'the renderer prints the method string but never computes it');
  assert.ok(!block.includes('* (1 -'), 'no net arithmetic in the browser');
  for (const claim of ["make_interval(days => v_attr)", "make_interval(days => v_lapse)",
    "require_module_scope_v145(p_business, null, 'reports')",
    "require_module_scope_v145(p_business, null, 'clients')",
    "require_module_scope_v145(p_business, null, 'sales')"]) {
    assert.ok(migration.includes(claim), `the migration owns: ${claim}`);
  }
});

test('V550 outreach evidence is immutable and deduped in the migration, not politely requested', () => {
  assert.ok(migration.includes('attention_outreach_v550_day_uk unique (business_id, client_id, occurred_on)'));
  assert.ok(migration.includes('before update or delete on public.attention_outreach_v550'));
  assert.ok(migration.includes('on conflict (business_id, client_id, occurred_on) do nothing'));
});
