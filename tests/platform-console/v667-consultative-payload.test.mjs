/* nestly_v667 — the consultant brief must render the payload the server actually sends.
 *
 * WHY THIS EXISTS. platform_get_assigned_firm_report_v94 emits `visits`, `returning_customers`
 * and a TOP-LEVEL `cohorts:{definitions,counts}`; the affinity RPC emits `support_orders` and
 * `confidence_pct`. The renderer read `transaction_count`, `returning_rate_pct`,
 * `customer_intelligence.cohorts`, `orders_together` and `attach_rate_pct` — names belonging to
 * a v94 definition that was superseded inside the same migration. Every one of them was
 * undefined, so the Returning-rate and Transactions tiles, the whole affinity table and the
 * whole customer-groups table rendered zero or empty regardless of the firm's real numbers.
 *
 * A source-regex test would not have caught this and must not be how it is guarded. These tests
 * EXECUTE the real renderer against a fixture shaped like the deployed RPC output, and the last
 * one closes the loop by checking the renderer's key reads against the migration's own emitted
 * key list — the missing UI/RPC contract validation that let the defect ship.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const console_js = readFileSync(join(root, 'app', 'platform-console.js'), 'utf8');
const v94 = readFileSync(
  join(root, 'db', 'migrations', '20260728_nestly_v94_platform_control_intelligence.sql'), 'utf8');
/* nestly_v722 re-patches platform_get_assigned_firm_report_v94 in place (extract-and-diff, not
   a fresh create-or-replace) to add 'evidence' and a section 'status' to kpis/cohorts/
   customer_intelligence — see docs/qa/CI-100-CHECKLIST.md check 93 and
   db/migrations/20260920_nestly_v722_freshness_and_brief_evidence.sql. The CONTRACT test below
   must see those two keys as live-emitted too, or it would wrongly flag the v727 fix that reads
   them as inventing an undefined key — the exact defect class this test exists to catch, just in
   the other direction. Scoped to v722's own patch-v94 block, not the whole migration file, so an
   unrelated key elsewhere in v722 cannot silently widen this contract. */
const v722 = readFileSync(
  join(root, 'db', 'migrations', '20260920_nestly_v722_freshness_and_brief_evidence.sql'), 'utf8');
const v722PatchStart = v722.indexOf('do $patch_v94$');
const v722PatchEnd = v722.indexOf('$patch_v94$;', v722PatchStart);
assert.ok(v722PatchStart > -1 && v722PatchEnd > v722PatchStart,
  'v722 must contain its platform_get_assigned_firm_report_v94 patch block');
const v722PatchV94 = v722.slice(v722PatchStart, v722PatchEnd);

const blockStart = console_js.indexOf('function consultativeIntelligenceHtml(');
const blockEnd = console_js.indexOf('async function renderEnterpriseReport(', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart,
  'consultativeIntelligenceHtml must be a top-level function before renderEnterpriseReport');
const block = console_js.slice(blockStart, blockEnd);

/* nestly_v734 (check 97): consultativeIntelligenceHtml now calls ciFreshnessCaptionHtmlV734,
   defined earlier in the file, outside this block slice — pulled in verbatim so this vm context
   can actually resolve it (see tests/business-ui/v734-ci-freshness-caption.test.mjs for the same
   pattern used against app.js). */
const freshnessStart = console_js.indexOf('function ciFreshnessCaptionHtmlV734(payload) {');
const freshnessEnd = console_js.indexOf('\n  }', freshnessStart) + '\n  }'.length;
assert.ok(freshnessStart > -1 && freshnessEnd > freshnessStart,
  'ciFreshnessCaptionHtmlV734 must exist as a top-level function');
const freshnessBlock = console_js.slice(freshnessStart, freshnessEnd);

/* The two static guards below scan the renderer for key names. They must read CODE, not prose:
   the fix's own comment names the superseded keys in order to explain them, and a scan that
   cannot tell the difference would either fail on the documentation or be silenced by deleting
   it. Strip comments first, so the guard is about what the renderer DOES. */
const code = block.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');

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

/* Shaped exactly like the live RPCs. TRUTH TABLE:
   40 active customers, 10 of them returning  -> 25.0% (10/40)
   137 visits, 4_560_00 cents revenue
   cohorts.counts champions 6 / loyal 12 / at_risk 3
   one affinity pair: support 9 of 60 sample orders -> 15.0% confidence, 11 units, 33_00 cents */
const REPORT = {
  scope: { business_id: 'b1', business_name: 'ZZ Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: {
    net_revenue_cents: 456000, visits: 137, active_customers: 40,
    returning_customers: 10, average_order_cents: 3328, currency: 'SGD'
  },
  cohorts: {
    definitions: {
      champions: '5+ purchases; last purchase in final 30 days',
      loyal: '2-4 purchases; last purchase in final 60 days',
      at_risk: '2+ purchases; last purchase 61-90 days before report end'
    },
    counts: { champions: 6, loyal: 12, at_risk: 3 }
  },
  data_quality: { confidence: 'ready', message: 'Item coverage is complete for this scope.' }
};
const AFFINITY = {
  enabled: true,
  pairs: [{
    service_id: 's1', service_name: 'Signature facial',
    product_id: 'p1', product_name: 'Cleanser',
    support_orders: 9, sample_orders: 60, confidence_pct: 15.0,
    product_units: 11, paired_revenue_cents: 3300
  }]
};
const RECS = { recommendations: [] };

test('v667 the KPI tiles read the emitted keys, not the superseded ones', () => {
  const html = render(REPORT, AFFINITY, RECS);
  assert.ok(html.includes('137'), 'Transactions must come from kpis.visits, not transaction_count');
  assert.ok(html.includes('SGD 4560.00'), 'Revenue must come from kpis.net_revenue_cents');
  assert.ok(html.includes('>40<'), 'Customers must come from kpis.active_customers');
  assert.ok(!/>0<\/div>/.test(html), 'no KPI tile may fall back to a zero when real data exists');
});

test('v667 the returning rate is derived and shows its numerator and denominator', () => {
  const html = render(REPORT, AFFINITY, RECS);
  assert.ok(html.includes('25.0%'), 'returning rate is 10/40 = 25.0%, derived not read');
  assert.ok(html.includes('(10/40)'),
    'a rate must travel with the counts it is a rate of, so the reader can see what it measures');
});

test('v667 an empty firm reports no customers rather than a 0.0% rate', () => {
  const html = render({ ...REPORT, kpis: { ...REPORT.kpis, active_customers: 0, returning_customers: 0 } },
    AFFINITY, RECS);
  assert.ok(html.includes('No customers in scope'),
    'a zero denominator must not render as 0.0%, which reads as a measured result');
  assert.ok(!html.includes('0.0%'), 'the misleading zero rate must not appear');
});

test('v667 customer groups render from the top-level cohorts object', () => {
  const html = render(REPORT, AFFINITY, RECS);
  assert.ok(html.includes('champions') && html.includes('>6<'), 'champions count must render');
  assert.ok(html.includes('loyal') && html.includes('>12<'), 'loyal count must render');
  assert.ok(html.includes('5+ purchases; last purchase in final 30 days'),
    'the emitted definition must be shown, so a group name is never unexplained');
  assert.ok(!html.includes('does not yet have enough customer-group data'),
    'a populated cohorts object must not render the empty state');
});

test('v667 groups are ordered by size and invent no columns the server never sent', () => {
  const html = render(REPORT, AFFINITY, RECS);
  assert.ok(html.indexOf('loyal') < html.indexOf('champions'), 'largest group first (12 before 6)');
  for (const absent of ['Orders', 'Revenue', 'Return rate']) {
    assert.ok(!html.includes(`<th>${absent}</th>`),
      `no per-cohort ${absent} is emitted, so the column must not exist rather than show zero`);
  }
});

test('v667 the affinity table renders support and confidence, with the denominator', () => {
  const html = render(REPORT, AFFINITY, RECS);
  assert.ok(html.includes('Signature facial') && html.includes('Cleanser'));
  assert.ok(html.includes('>9<'), 'support_orders is the "together" count');
  assert.ok(html.includes('>60<'), 'sample_orders is the denominator that confidence is a share of');
  assert.ok(html.includes('15.0%'), 'confidence_pct is the attach rate');
  assert.ok(!html.includes('No reliable product/service pair'),
    'a qualifying pair must not render the empty state');
});

test('v667 CONTRACT: every payload key the renderer reads is one the LIVE SQL emits', () => {
  /* The defect class, guarded directly: collect the keys the renderer reads off the server
     objects, then require each to appear as an emitted key in the v94 migration.

     LIVE DEFINITIONS ONLY. Independent verification found the original file-wide scan also
     harvested keys from the SUPERSEDED definitions earlier in the same migration — including
     orders_together and attach_rate_pct, two of the four keys the original defect shipped on —
     so half the defect class slipped through this test and was caught only by the hardcoded
     blacklist below. Each function's LAST definition in the file is the one PostgreSQL keeps,
     so keys are extracted from the final definition of each consumed function only. */
  const liveBody = (fn) => {
    const header = `create or replace function public.${fn}(`;
    const start = v94.lastIndexOf(header);
    assert.ok(start > -1, `v94 must define ${fn}`);
    const end = v94.indexOf('$$;', start);
    assert.ok(end > start, `unterminated body for ${fn}`);
    return v94.slice(start, end);
  };
  const liveSql = liveBody('platform_get_assigned_firm_report_v94')
                + liveBody('platform_get_catalogue_affinity_v94')
                + v722PatchV94;
  const emitted = new Set([...liveSql.matchAll(/'([a-z_]+)'\s*,/g)].map(m => m[1]));
  /* Sanity: the superseded names must NOT be in the live emitted set, or the slice is wrong. */
  for (const dead of ['orders_together', 'attach_rate_pct']) {
    assert.ok(!emitted.has(dead),
      `"${dead}" was harvested into the emitted set — the live-definition slice is not working`);
  }

  const readsKpis = [...code.matchAll(/\bkpis\.([a-z_]+)/g)].map(m => m[1]);
  const readsPair = [...code.matchAll(/\brow\.([a-z_]+)\s*\?\?/g)].map(m => m[1]);

  const localOnly = new Set(['currency']); // supplied by the caller's scope, not the RPC payload
  for (const key of [...readsKpis, ...readsPair]) {
    if (localOnly.has(key)) continue;
    assert.ok(emitted.has(key),
      `the renderer reads "${key}" but no v94 jsonb_build_object emits it — this is exactly ` +
      `how transaction_count / returning_rate_pct / orders_together / attach_rate_pct shipped`);
  }
});

test('v667 the renderer no longer references any superseded key name', () => {
  for (const dead of ['transaction_count', 'completed_transactions', 'returning_rate_pct',
                      'orders_together', 'attach_rate_pct', 'customer_count']) {
    assert.ok(!code.includes(dead),
      `"${dead}" belongs to the superseded v94 definition and always evaluated undefined`);
  }
});
