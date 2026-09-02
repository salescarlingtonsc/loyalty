/* nestly_v727 (docs/qa/CI-100-CHECKLIST.md check 93) — the consultant brief must never dress an
 * evidence-insufficient section up as a healthy zero.
 *
 * REFUTER FINDING (executed). consultativeIntelligenceHtml in app/platform-console.js never read
 * kpis.status/evidence, cohorts.status/evidence or customer_intelligence.status/evidence. Fed the
 * real K1 'unavailable' payload shape that
 * db/migrations/20260902_nestly_v722_freshness_and_brief_evidence.sql now emits from
 * public.platform_get_assigned_firm_report_v94 (identified-customer count below the
 * app.subgroup_evidence_v1 floor of 5), it printed "SGD 0.00" for kpis.average_order_cents and
 * customer_intelligence.top_customer_revenue_cents and never the words "not enough data" —
 * indistinguishable from a real, healthy, zero-revenue period.
 *
 * The fix: when a section's status is 'unavailable', the renderer now shows
 * "Not enough data yet (n of floor customers)" for that section's rate-like/identity figure
 * (average order, top customer revenue) instead of a currency amount, and NEVER prints a currency
 * or percentage for that figure. Counts (cohort counts, identified/with-purchase/inactive
 * customers) still render — a count is not a rate, and zero is a legitimate count. When status is
 * 'ok', figures render exactly as before (v667).
 *
 * These tests EXECUTE the real renderer (same vm harness as v667-consultative-payload.test.mjs)
 * against (a) the K1 unavailable payload shape and (b) a K2 'ok' payload shape.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const console_js = readFileSync(join(root, 'app', 'platform-console.js'), 'utf8');

const blockStart = console_js.indexOf('function consultativeIntelligenceHtml(');
const blockEnd = console_js.indexOf('async function renderEnterpriseReport(', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart,
  'consultativeIntelligenceHtml must be a top-level function before renderEnterpriseReport');
const block = console_js.slice(blockStart, blockEnd);

/* nestly_v734 (check 97): consultativeIntelligenceHtml now calls ciFreshnessCaptionHtmlV734,
   defined earlier in the file (next to dateTime), outside this block slice — so it is pulled in
   verbatim here, same "execute the real helper" posture as the rest of this file. */
const freshnessStart = console_js.indexOf('function ciFreshnessCaptionHtmlV734(payload) {');
const freshnessEnd = console_js.indexOf('\n  }', freshnessStart) + '\n  }'.length;
assert.ok(freshnessStart > -1 && freshnessEnd > freshnessStart,
  'ciFreshnessCaptionHtmlV734 must exist as a top-level function');
const freshnessBlock = console_js.slice(freshnessStart, freshnessEnd);

function render(report, affinity, recommendations) {
  const esc = (x) => String(x ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const sandbox = {
    escapeHtml: esc,
    asObject: (x) => (x && typeof x === 'object' && !Array.isArray(x)) ? x : {},
    asArray: (x) => Array.isArray(x) ? x : [],
    currency: (c, cur) => `${cur || 'SGD'} ${((Number(c) || 0) / 100).toFixed(2)}`,
    dateTime: (v) => `DT:${v}`,
    pt: (s, vars) => vars
      ? Object.keys(vars).reduce((out, k) => out.replaceAll(`{${k}}`, String(vars[k])), s)
      : s,
    platformStatus: (s) => String(s ?? ''),
    localizedEmptyHtml: (msg) => `<div class="empty">${esc(msg)}</div>`,
    localizedRouteNoteHtml: (t, b) => `<div class="note"><b>${esc(t)}</b><p>${esc(b)}</p></div>`,
    CUI: {
      status: (label) => `<span class="status">${esc(label)}</span>`,
      icon: () => '',
      card: ({ title, body }) => `<section class="card"><h3>${esc(title)}</h3>${body}</section>`,
      table: ({ headers, rows }) =>
        `<table><thead><tr>${headers.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead>` +
        `<tbody>${rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`
    }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(freshnessBlock + '\n' + block + '\n__exports.render = consultativeIntelligenceHtml;', context);
  return context.__exports.render(report, affinity, recommendations, sandbox.CUI);
}

/* K1 — the real shape v722 emits for a firm whose identified-customer count (2) is below the
   default floor of 5: average_order_cents and top_customer_revenue_cents are null, evidence/
   status appear on kpis, cohorts and customer_intelligence, but every COUNT is still a real
   number (never hidden or zeroed-out just because the section is gated). */
const K1_UNAVAILABLE = {
  scope: { business_id: 'b1', business_name: 'Tiny Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: {
    net_revenue_cents: 15000, visits: 3, active_customers: 2, returning_customers: 0,
    average_order_cents: null, currency: 'SGD',
    evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable'
  },
  cohorts: {
    definitions: { champions: '5+ purchases; last purchase in final 30 days' },
    counts: { champions: 0, loyal: 1, at_risk: 1 },
    evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable'
  },
  customer_intelligence: {
    total_customers: 2, customers_with_purchase: 2, customers_over_90_days_inactive: 0,
    top_customer_revenue_cents: null,
    evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable'
  },
  data_quality: { confidence: 'not_enough_data', message: 'Below the evidence floor.' }
};
const K1_AFFINITY = { enabled: true, pairs: [] };
const K1_RECS = { recommendations: [] };

/* K2 — an ordinary healthy firm at/above the floor: status 'ok' everywhere, real figures render
   exactly as v667 already proved. */
const K2_OK = {
  scope: { business_id: 'b2', business_name: 'Healthy Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: {
    net_revenue_cents: 456000, visits: 137, active_customers: 40, returning_customers: 10,
    average_order_cents: 3328, currency: 'SGD',
    evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok'
  },
  cohorts: {
    definitions: { champions: '5+ purchases; last purchase in final 30 days' },
    counts: { champions: 6, loyal: 12, at_risk: 3 },
    evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok'
  },
  customer_intelligence: {
    total_customers: 40, customers_with_purchase: 35, customers_over_90_days_inactive: 5,
    top_customer_revenue_cents: 98000,
    evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok'
  },
  data_quality: { confidence: 'ready', message: 'Item coverage is complete for this scope.' }
};
const K2_AFFINITY = { enabled: true, pairs: [] };
const K2_RECS = { recommendations: [] };

test('v727 unavailable kpis section shows the evidence note, never SGD 0.00', () => {
  const html = render(K1_UNAVAILABLE, K1_AFFINITY, K1_RECS);
  assert.ok(html.includes('Not enough data yet (2 of 5 customers)'),
    'average order must show the evidence note (n of floor) when kpis.status is unavailable');
  assert.ok(!html.includes('SGD 0.00'),
    'an evidence-insufficient average order must never render as a currency amount, gated or not');
});

test('v727 unavailable customer_intelligence section shows the evidence note, never a currency', () => {
  const html = render(K1_UNAVAILABLE, K1_AFFINITY, K1_RECS);
  const occurrences = html.split('Not enough data yet (2 of 5 customers)').length - 1;
  assert.ok(occurrences >= 2,
    'both the gated kpis figure and the gated customer_intelligence figure need the note ' +
    `(found ${occurrences})`);
});

test('v727 counts still render on an unavailable section — a count is not a rate', () => {
  const html = render(K1_UNAVAILABLE, K1_AFFINITY, K1_RECS);
  assert.ok(html.includes('>2<'), 'kpis.active_customers=2 must still render as a real count');
  assert.ok(html.includes('>1<'), 'a real cohort count (loyal=1 / at_risk=1) must still render');
  assert.ok(html.includes('>0<'),
    'customer_intelligence.customers_over_90_days_inactive=0 is a legitimate count and must ' +
    'still render as 0, unlike the gated rate-like figures');
});

test('v727 an ok payload renders real figures, not the evidence note', () => {
  const html = render(K2_OK, K2_AFFINITY, K2_RECS);
  assert.ok(!html.includes('Not enough data yet'),
    'a status:"ok" payload must never show the insufficient-evidence note');
  assert.ok(html.includes('SGD 33.28'), 'average_order_cents=3328 must render as SGD 33.28');
  assert.ok(html.includes('SGD 980.00'), 'top_customer_revenue_cents=98000 must render as SGD 980.00');
});

test('v727 CONTRACT: the renderer reads status/evidence off kpis and customer_intelligence', () => {
  const code = block.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');
  assert.match(code, /kpis\.status/, 'the renderer must gate on kpis.status');
  assert.match(code, /kpis\.evidence/, 'the renderer must read kpis.evidence for its note');
  assert.match(code, /intelligence\.status/, 'the renderer must gate on customer_intelligence.status');
  assert.match(code, /intelligence\.evidence/,
    'the renderer must read customer_intelligence.evidence for its note');
});
