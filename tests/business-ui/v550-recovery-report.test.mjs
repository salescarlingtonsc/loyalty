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

/* ---- v652: the report leads with its evidence, not with a dollar figure ------------------
   The comparison group in this report is NOT a randomised holdout — it is whoever was not
   contacted — so nestly_v652 attaches an evidence block whose verdict is structurally capped
   at 'early_signal'. These cases EXECUTE the renderer against the three states the RPC can
   actually produce; the legacy case (no evidence key) must keep rendering exactly as before. */

const V652_LIMITATIONS = [
  'The comparison group was not randomly assigned — it is whoever was not contacted, so the two groups may differ in ways this report cannot see.',
  'Revenue is credited to any paying visit within 30 days of contact, whether or not the offer was redeemed.',
  'Net revenue is floored at zero, so this figure can never show a campaign performing worse than the comparison group.'
];

function withEvidence(overrides) {
  return { ...FIXTURE, evidence: {
    population: 'Customers contacted after at least 14 days away',
    denominator: 'Contacted customers who were lapsed at the time of contact',
    window: { from: '2026-07-12', to: '2026-08-27' },
    sample: { treated: 4, treated_events: 3, comparison: 2, comparison_events: 1 },
    comparison: 'Similarly lapsed customers who happened to receive no contact in this window',
    rates: { treated_pct: 75.0, comparison_pct: 50.0 },
    difference: null,
    verdict: 'insufficient',
    verdict_ceiling: 'early_signal',
    limitations: V652_LIMITATIONS,
    observed_since: null,
    ...overrides } };
}

const EARLY_SIGNAL = withEvidence({
  sample: { treated: 100, treated_events: 34, comparison: 100, comparison_events: 21 },
  rates: { treated_pct: 34.0, comparison_pct: 21.0 },
  difference: { absolute_pp: 13.0, relative: 1.62, confidence_95_pp: [2.1, 23.9],
    method: 'normal approximation, 95% interval on the difference in rates' },
  verdict: 'early_signal'
});

test('V652 an insufficient verdict withholds the dollar headline instead of leading with it', () => {
  const html = render(withEvidence({}));
  assert.ok(html.includes('revenue-opportunity--withheld'),
    'the withheld state reuses the same idiom Customer Intelligence uses to withhold a suggestion');
  assert.ok(!html.includes('<b>Recovered revenue (estimated)</b>'),
    'the confident headline must not appear while the groups cannot be told apart');
  assert.ok(!/class="metric"[^>]*>SGD 33\.33/.test(html),
    'the net figure must not be presented as the headline metric in this state');
  assert.ok(html.includes('SGD 33.33'),
    'the figure is still reachable for reference — demoted, not deleted');
  assert.ok(html.includes('<b>4</b>') && html.includes('<b>2</b>'),
    'both arm sizes are stated so the reader can see why it is withheld');
});

test('V652 an early signal shows the figure but subordinates it to the rate difference', () => {
  const html = render(EARLY_SIGNAL);
  assert.ok(html.includes('Early signal'), 'the verdict labels the card');
  assert.ok(html.includes('class="metric"') && html.includes('SGD 33.33'),
    'the dollar figure is shown in this state');
  assert.ok(html.includes('34.0%') && html.includes('21.0%'),
    'both return rates are shown, never the treated rate alone');
  assert.ok(html.includes('+13.0pp'), 'the absolute difference is stated in percentage points');
  assert.ok(html.includes('+2.1pp') && html.includes('+23.9pp'),
    'the 95% range travels with the difference — a point estimate alone would overstate it');
  assert.ok(!html.includes('Strong pattern'),
    'a non-randomised comparison may never be presented as a strong pattern');
});

test('V652 a strong_pattern verdict is rendered defensively as an early signal', () => {
  /* The server caps this at early_signal, so it cannot occur; if it ever did, the renderer
     must not upgrade the claim on the strength of a value it should never have received. */
  const html = render(withEvidence({
    sample: { treated: 100, treated_events: 34, comparison: 100, comparison_events: 21 },
    rates: { treated_pct: 34.0, comparison_pct: 21.0 },
    difference: { absolute_pp: 13.0, relative: 1.62, confidence_95_pp: [2.1, 23.9],
      method: 'normal approximation, 95% interval on the difference in rates' },
    verdict: 'strong_pattern' }));
  assert.ok(html.includes('Early signal'), 'the ceiling is honoured by the renderer too');
  assert.ok(!html.includes('Strong pattern'));
});

test('V652 every limitation is rendered verbatim, never paraphrased or truncated', () => {
  for (const html of [render(withEvidence({})), render(EARLY_SIGNAL)]) {
    for (const limitation of V652_LIMITATIONS) {
      assert.ok(html.includes(limitation),
        `a reader cannot quote the number honestly without this caveat: ${limitation.slice(0, 48)}…`);
    }
  }
});

test('V652 a response without an evidence block still renders the original report', () => {
  const html = render(FIXTURE);
  assert.ok(html.includes('Recovered revenue (estimated)'),
    'older cached payloads keep working unchanged');
  assert.ok(!html.includes('revenue-opportunity--withheld'));
  assert.ok(!html.includes('Early signal'));
});
