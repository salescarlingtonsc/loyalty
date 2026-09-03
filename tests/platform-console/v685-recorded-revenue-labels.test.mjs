/* NESTLY v685 (check 2) — every revenue figure on the platform-console.js consultant brief AND
   the platform KPI tiles must carry the exact canonical "Peekaa recorded revenue" phrasing (the
   label app/revenue-truth.js already uses verbatim in its `metricCard('Peekaa recorded revenue', ...)`
   call), never a bare "Revenue" label on a recorded figure. A bare "Revenue" label invites reading
   a Peekaa-ledger figure as "total business revenue" — a claim Peekaa cannot make (see
   app/revenue-truth.js's own recordedHelper: "This does not prove merchant-source completeness, so
   total business revenue remains unavailable.").

   Two surfaces are executed here, the same way v667 executes consultativeIntelligenceHtml:
     1. consultativeIntelligenceHtml (the monthly consultant brief) — its KPI row.
     2. scopedReportHtml (a platform KPI-tiles surface) — its KPI row.

   Both previously read `['Revenue', currency(...), 'reports']` for a real recorded figure; both
   are now `['Peekaa recorded revenue', currency(...), 'reports']`. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const console_js = readFileSync(join(root, 'app', 'platform-console.js'), 'utf8');
const revenueTruthSrc = readFileSync(join(root, 'app', 'revenue-truth.js'), 'utf8');

/* The canonical wording is not hardcoded here — it is lifted from app/revenue-truth.js's own
   metricCard call, so this test fails loudly if that canonical string ever changes and this file
   was not updated to match. */
const canonicalMatch = revenueTruthSrc.match(/metricCard\('([^']+)'/);
assert.ok(canonicalMatch, 'app/revenue-truth.js must define the canonical recorded-revenue label via metricCard(...)');
const CANONICAL_LABEL = canonicalMatch[1];
assert.equal(CANONICAL_LABEL, 'Peekaa recorded revenue');

function esc(x) {
  return String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function currency(cents, cur) {
  const safe = Number.isFinite(Number(cents)) ? Number(cents) : 0;
  return `${cur || 'SGD'} ${(safe / 100).toFixed(2)}`;
}

/* --- Surface 1: consultativeIntelligenceHtml (the consultant brief) --- */

const brief_start = console_js.indexOf('function consultativeIntelligenceHtml(');
const brief_end = console_js.indexOf('async function renderEnterpriseReport(', brief_start);
assert.ok(brief_start > -1 && brief_end > brief_start, 'consultativeIntelligenceHtml must be a top-level function');
const briefBlock = console_js.slice(brief_start, brief_end);

/* nestly_v734 (check 97): consultativeIntelligenceHtml now calls ciFreshnessCaptionHtmlV734,
   defined earlier in the file, outside this block slice — pulled in verbatim so this vm context
   can actually resolve it. */
const freshnessStart = console_js.indexOf('function ciFreshnessCaptionHtmlV734(payload) {');
const freshnessEnd = console_js.indexOf('\n  }', freshnessStart) + '\n  }'.length;
assert.ok(freshnessStart > -1 && freshnessEnd > freshnessStart,
  'ciFreshnessCaptionHtmlV734 must exist as a top-level function');
const freshnessBlock = console_js.slice(freshnessStart, freshnessEnd);

function renderBrief(report, affinity, recommendations) {
  const sandbox = {
    escapeHtml: esc,
    asObject: (x) => (x && typeof x === 'object' && !Array.isArray(x)) ? x : {},
    asArray: (x) => Array.isArray(x) ? x : [],
    currency,
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
  vm.runInContext(freshnessBlock + '\n' + briefBlock + '\n__exports.render = consultativeIntelligenceHtml;', context);
  return context.__exports.render(report, affinity, recommendations, sandbox.CUI);
}

const REPORT = {
  scope: { business_id: 'b1', business_name: 'ZZ Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: {
    net_revenue_cents: 456000, visits: 137, active_customers: 40,
    returning_customers: 10, average_order_cents: 3328, currency: 'SGD'
  },
  cohorts: { definitions: {}, counts: {} },
  data_quality: { confidence: 'ready', message: 'Item coverage is complete for this scope.' }
};
const AFFINITY = { enabled: true, pairs: [] };
const RECS = { recommendations: [] };

test('v685 consultant brief: the revenue KPI tile carries the exact canonical label', () => {
  const html = renderBrief(REPORT, AFFINITY, RECS);
  assert.ok(html.includes(CANONICAL_LABEL),
    `the consultant brief must label its recorded revenue figure "${CANONICAL_LABEL}"`);
  assert.ok(html.includes('SGD 4560.00'), 'the figure itself must still be the real net_revenue_cents value');
});

test('v685 consultant brief: never claims "Total business revenue"', () => {
  const html = renderBrief(REPORT, AFFINITY, RECS);
  assert.ok(!html.includes('Total business revenue'),
    'Peekaa cannot prove merchant-source completeness, so this claim must never appear');
});

/* --- Surface 2: scopedReportHtml (a platform KPI-tiles surface) --- */

const scoped_start = console_js.indexOf('function scopedReportHtml(');
const scoped_end = console_js.indexOf('async function renderScopedReports(', scoped_start);
assert.ok(scoped_start > -1 && scoped_end > scoped_start, 'scopedReportHtml must be a top-level function');
const scopedBlock = console_js.slice(scoped_start, scoped_end);

function renderScoped(report) {
  const sandbox = {
    escapeHtml: esc,
    asObject: (x) => (x && typeof x === 'object' && !Array.isArray(x)) ? x : {},
    asArray: (x) => Array.isArray(x) ? x : [],
    currency,
    pt: (s) => s,
    dateTime: (v) => String(v ?? ''),
    sectorLabel: (v) => String(v ?? '')
  };
  const CUI = {
    icon: () => '',
    table: ({ headers, rows }) =>
      `<table><thead><tr>${headers.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead>` +
      `<tbody>${rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(scopedBlock + '\n__exports.render = scopedReportHtml;', context);
  return context.__exports.render(report, CUI);
}

const SCOPED_REPORT = {
  scope: { generated_at: '2026-08-31T00:00:00Z' },
  summary: { business_count: 3, customer_count: 120, sales_count: 400, revenue_cents: 250000 },
  businesses: [{ name: 'ZZ Firm', industry: 'fnb', customers: 40, revenue_cents: 100000 }]
};

test('v685 platform KPI tiles (scopedReportHtml): the revenue KPI tile carries the exact canonical label', () => {
  const html = renderScoped(SCOPED_REPORT);
  assert.ok(html.includes(CANONICAL_LABEL),
    `the scoped report's platform KPI tiles must label the recorded revenue figure "${CANONICAL_LABEL}"`);
  assert.ok(html.includes('SGD 2500.00'), 'the figure itself must still be the real revenue_cents value');
});

test('v685 platform KPI tiles: never claims "Total business revenue"', () => {
  const html = renderScoped(SCOPED_REPORT);
  assert.ok(!html.includes('Total business revenue'));
});

/* --- Whole-file guard: no other bare "Revenue" label sits on a recorded (non-projection) figure
   inside either the consultant brief block or the scoped-report block. This is a source guard,
   scoped tightly to the two executed blocks above, not a file-wide grep — the platform overview's
   own "Revenue: Projection only" definition-list entry is a different, explicitly-labelled concept
   and is out of scope. */
test('v685 CONTRACT: neither executed block emits a bare [\'Revenue\', ...] KPI-tile entry any more', () => {
  for (const [label, block] of [['consultativeIntelligenceHtml', briefBlock], ['scopedReportHtml', scopedBlock]]) {
    assert.ok(!/\[\s*'Revenue'\s*,/.test(block),
      `${label} must not emit a bare 'Revenue' KPI-tile label for a recorded figure`);
  }
});
