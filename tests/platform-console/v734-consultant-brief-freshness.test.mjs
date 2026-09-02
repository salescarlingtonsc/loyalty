/* NESTLY v734 (check 97: freshness and stale states) — the consultant brief
 * (consultativeIntelligenceHtml in app/platform-console.js) gets its own copy of app.js's
 * ciFreshnessCaptionHtmlV734 renderer (no shared module boundary between the two bundles), wired
 * in right under the brief's header/status row.
 *
 * public.platform_get_assigned_firm_report_v94 does NOT currently get a top-level `freshness`
 * key from v722 (only kpis/cohorts/customer_intelligence got their evidence gating — see
 * db/migrations/20260902_nestly_v722_freshness_and_brief_evidence.sql, Part B/C). The helper must
 * therefore render nothing today (freshness-absent case) without throwing, while still being
 * ready the day that RPC's own envelope grows one — proven here by feeding the helper a payload
 * shaped like the shared app.ci_envelope_v680 freshness block, lifted from
 * db/tests/executed/v722_corpus_freshness_brief.sql's F1 (fresh) / F2 (stale) / F3 (no data)
 * scenarios, the same fixtures used in tests/business-ui/v734-ci-freshness-caption.test.mjs.
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
assert.ok(blockStart > -1 && blockEnd > blockStart);
const block = console_js.slice(blockStart, blockEnd);

const freshnessStart = console_js.indexOf('function ciFreshnessCaptionHtmlV734(payload) {');
const freshnessEnd = console_js.indexOf('\n  }', freshnessStart) + '\n  }'.length;
assert.ok(freshnessStart > -1 && freshnessEnd > freshnessStart,
  'ciFreshnessCaptionHtmlV734 must exist as a top-level function in platform-console.js');
const freshnessBlock = console_js.slice(freshnessStart, freshnessEnd);

function makeSandbox() {
  const esc = (x) => String(x ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  return {
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
}

function renderCaption(payload) {
  const sandbox = makeSandbox();
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(freshnessBlock + '\n__exports.caption=ciFreshnessCaptionHtmlV734;', context);
  return context.__exports.caption(payload);
}

function renderBrief(report) {
  const sandbox = makeSandbox();
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(freshnessBlock + '\n' + block + '\n__exports.render=consultativeIntelligenceHtml;', context);
  return context.__exports.render(report, { enabled: true, pairs: [] }, { recommendations: [] }, sandbox.CUI);
}

const BASE_K2 = {
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

/* Fixtures lifted from db/tests/executed/v722_corpus_freshness_brief.sql (F1/F2/F3), same values
   used by tests/business-ui/v734-ci-freshness-caption.test.mjs. */
const FRESHNESS_FRESH = {
  data_as_of: '2026-09-02T09:00:00Z', observed_since: '2026-08-01T00:00:00Z',
  generated_at: '2026-09-02T10:00:00Z', age_hours: 1.0, stale: false,
  note: 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
};
const FRESHNESS_STALE = {
  data_as_of: '2026-08-29T06:00:00Z', observed_since: '2026-08-01T00:00:00Z',
  generated_at: '2026-09-02T10:00:00Z', age_hours: 100.0, stale: true,
  note: 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
};
const FRESHNESS_NO_DATA = {
  data_as_of: null, observed_since: null, generated_at: '2026-09-02T10:00:00Z',
  age_hours: null, stale: true,
  note: 'No sales recorded yet for this scope; treat any finding as provisional.'
};

test('v734 platform-console caption: fresh renders "Data as of <date> · <age>", no stale line', () => {
  const html = renderCaption({ freshness: FRESHNESS_FRESH });
  assert.ok(html.includes('Data as of DT:2026-09-02T09:00:00Z'));
  assert.ok(html.includes('1.0 hours old') || html.includes('1.0 hour old'));
  assert.ok(!html.includes('may be out of date'));
});

test('v734 platform-console caption: stale adds the disclosure with the server note verbatim', () => {
  const html = renderCaption({ freshness: FRESHNESS_STALE });
  assert.ok(html.includes('Data may be out of date'));
  assert.ok(html.includes(FRESHNESS_STALE.note));
});

test('v734 platform-console caption: zero sales renders "no recorded sale yet" / "age unknown", never a crash', () => {
  const html = renderCaption({ freshness: FRESHNESS_NO_DATA });
  assert.ok(html.includes('no recorded sale yet'));
  assert.ok(html.includes('age unknown'));
  assert.ok(html.includes(FRESHNESS_NO_DATA.note));
});

test('v734 platform-console caption: freshness-absent (today’s real v94 shape) renders nothing, no crash', () => {
  assert.equal(renderCaption(BASE_K2), '');
  assert.equal(renderCaption(null), '');
  assert.equal(renderCaption({}), '');
  assert.doesNotThrow(() => renderCaption(undefined));
});

test('v734 wiring: consultativeIntelligenceHtml calls the shared freshness helper and still renders in full when stale', () => {
  const staleReport = { ...BASE_K2, freshness: FRESHNESS_STALE };
  const html = renderBrief(staleReport);
  assert.ok(html.includes('Data may be out of date'), 'the brief must surface the stale disclosure');
  assert.ok(html.includes(FRESHNESS_STALE.note));
  assert.ok(html.includes('SGD 33.28'), 'a stale freshness block must never withhold the brief’s real KPIs — disclosure only');
});

test('v734 wiring: consultativeIntelligenceHtml with today’s real (freshness-absent) v94 payload renders unchanged', () => {
  const html = renderBrief(BASE_K2);
  assert.ok(!html.includes('ci-freshness-caption-v734'), 'no freshness key on the report means no caption markup');
  assert.ok(html.includes('SGD 33.28'));
});

test('v734 wiring: consultativeIntelligenceHtml source calls ciFreshnessCaptionHtmlV734(report)', () => {
  assert.match(block, /ciFreshnessCaptionHtmlV734\(report\)/);
});
