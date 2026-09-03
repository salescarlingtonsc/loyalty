/* NESTLY v704 — Customer Intelligence category mix, check 66 (outlier analysis) consumed in the
 * merchant UI.
 *
 * db/migrations/20260920_nestly_v691_outliers_and_confounders.sql made get_ci_category_mix_v1
 * and get_ci_service_intelligence_v1 emit a per-row `distribution` block (n, mean, median, p90,
 * top1_share_bps, skew_material, mean_excl_top1 — app.distribution_block_v1's own keys, v672)
 * plus a `skew_note` string, but nothing rendered them (check 66 scored PARTIAL,
 * docs/qa/CI-100-CHECKLIST.md line 114). get_ci_service_intelligence_v1 is never called from
 * app.js (grep confirms zero call sites), so only get_ci_category_mix_v1's consumer —
 * categoryMixMarkupV650, via the new helper ciCategoryDistributionRowMarkupV704 — gets a
 * renderer here.
 *
 * This extracts the same self-contained closure slice tests/business-ui/v685-ci-surfaces.test.mjs
 * already uses (state vars + helpers + the v650 panel renderers) and executes it in a vm
 * context, the same "execute the real renderer, not a regex over source" posture as v685/v679.
 *
 * Fixture numbers are the v691 migration's own hand-computed truth table
 * (db/tests/executed/v691_corpus_outliers_confounders.sql, "PART A"):
 *   WHALE category: n=5, mean=2000 (cents), median=1000, top1_share_bps=6000 (60.0%),
 *     skew_material=true, mean_excl_top1=1000, skew_note = server-provided sentence.
 *   FLAT category:  n=4, mean=median=1000, top1_share_bps=2500, skew_material=false,
 *     skew_note=null (server never fabricates one when skew isn't material).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

// get_ci_service_intelligence_v1 has no call site in app.js at all (grep confirms), so per the
// task's own instruction this file only covers get_ci_category_mix_v1's consumer.
assert.ok(!app.includes("sb.rpc('get_ci_service_intelligence_v1'"),
  'get_ci_service_intelligence_v1 must still have no merchant-UI call site — if one is added, this file needs a matching test');

// The renderer under test must never derive a percentage itself — only format the server's
// own top1_share_bps. Guard the source once here so a future edit can't quietly reintroduce
// client-side arithmetic on other distribution fields.
assert.ok(
  !/top1_share_bps\s*\/\s*(?!100\b)\d/.test(app),
  'must not divide top1_share_bps by anything other than 100 (bps -> pct formatting)'
);

/* -------------------------------------------------------------------------------------------
   Extract the same closure slice as v685: state vars + helpers + the v650 renderers (which now
   includes ciCategoryDistributionRowMarkupV704, defined immediately before categoryMixMarkupV650,
   inside this same range).
   ------------------------------------------------------------------------------------------- */
const stateStart = app.indexOf("let lastAcquisitionBundle=null,lastAcquisitionError=''");
const stateEnd = app.indexOf('const CUSTOMER_INTELLIGENCE_PAGE_SIZE=100;');
assert.ok(stateStart > -1 && stateEnd > stateStart, 'state-var slice anchors must exist');
const stateBlock = app.slice(stateStart, stateEnd + 'const CUSTOMER_INTELLIGENCE_PAGE_SIZE=100;'.length);

const rendererStart = app.indexOf("const scopeMoney=(cents,currency=S.biz.currency||'SGD')=>");
const rendererEnd = app.indexOf('function ciCategoryMixWrapV650(){', rendererStart);
assert.ok(rendererStart > -1 && rendererEnd > rendererStart, 'renderer slice anchors must exist');
const rendererBlock = app.slice(rendererStart, rendererEnd);

assert.ok(rendererBlock.includes('function ciCategoryDistributionRowMarkupV704('),
  'the v704 distribution renderer must live inside the extracted closure slice');

const closureBlock = stateBlock + '\n' + rendererBlock;

/* nestly_v734 (check 97): categoryMixMarkupV650 calls the real top-level ciFreshnessCaptionHtmlV734
   defined further down app.js (outside this closure slice) — pulled in verbatim, same pattern
   tests/business-ui/v685-ci-surfaces.test.mjs uses. */
const freshnessHelperStart = app.indexOf('function ciFreshnessCaptionHtmlV734(payload){');
const freshnessHelperEnd = app.indexOf('\n}', freshnessHelperStart) + 2;
assert.ok(freshnessHelperStart > -1 && freshnessHelperEnd > freshnessHelperStart,
  'ciFreshnessCaptionHtmlV734 must exist as a top-level function');
const freshnessHelperBlock = app.slice(freshnessHelperStart, freshnessHelperEnd);

function makePage() {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    walletDate: (v) => `WD:${v}`,
    S: { biz: { currency: 'SGD' } }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    freshnessHelperBlock + '\n' +
    closureBlock +
    `\n__exports.categoryMix=()=>categoryMixMarkupV650();` +
    `__exports.setCategoryMix=(bundle,err)=>{lastCategoryMixBundle=bundle;lastCategoryMixError=err||'';};`,
    context
  );
  return context.__exports;
}

const WHALE_DIST = {
  n: 5, mean: 2000, median: 1000, p90: 6000, top1_share_bps: 6000,
  skew_material: true, mean_excl_top1: 1000
};
const WHALE_SKEW_NOTE =
  'top customer carries 60.0% of this category; the mean overstates the typical customer';
const FLAT_DIST = {
  n: 4, mean: 1000, median: 1000, p90: 1000, top1_share_bps: 2500,
  skew_material: false, mean_excl_top1: 1000
};

function bundleWith(categories) {
  return {
    status: 'ready',
    coverage: { classified_pct_bps: 10000, projected_share_bps: 0 },
    categories,
    observed_since: '2026-08-01T00:00:00Z'
  };
}

test('V704 category mix: the whale row shows median vs mean, the 60% top-customer share, and the server skew_note verbatim', () => {
  const page = makePage();
  page.setCategoryMix(bundleWith([{
    node_key: 'beauty.facials', label: 'Facials', revenue_cents: 10000, customer_count: 5,
    distribution: WHALE_DIST, skew_note: WHALE_SKEW_NOTE
  }]), '');
  const html = page.categoryMix();

  assert.ok(html.includes('Concentration'), 'a <=3-word label must be present');
  assert.ok(html.includes('SGD 10.00'), 'median (1000 cents) must render');
  assert.ok(html.includes('SGD 20.00'), 'mean (2000 cents) must render');
  assert.ok(html.includes('60.0%'), 'top1_share_bps (6000) formatted as 60.0%, not recomputed');
  assert.ok(html.includes(WHALE_SKEW_NOTE), 'the server\'s skew_note must appear verbatim');
});

test('V704 category mix: a flat (non-skewed) row renders no invented numbers and no skew_note', () => {
  const page = makePage();
  page.setCategoryMix(bundleWith([{
    node_key: 'beauty.nails', label: 'Nails', revenue_cents: 4000, customer_count: 4,
    distribution: FLAT_DIST, skew_note: null
  }]), '');
  const html = page.categoryMix();

  // The flat row still gets its median/mean/top-share line (distribution.n=4 >= floor 5? No —
  // it's exactly the k=5 floor from subgroup_evidence_v1/v672; 4 < 5, so this row is BELOW the
  // floor and must render NOTHING extra, per the task's floor rule.
  assert.ok(!html.includes('Concentration'), 'below-floor rows render no distribution extras');
  assert.ok(!/top customer carries/.test(html), 'no fabricated skew_note for a below-floor row');
});

test('V704 category mix: an at/above-floor flat row renders the concentration line but no skew_note (skew_material=false)', () => {
  const page = makePage();
  const flatAtFloor = { ...FLAT_DIST, n: 5, top1_share_bps: 2000 };
  const page2 = page;
  page2.setCategoryMix(bundleWith([{
    node_key: 'beauty.nails', label: 'Nails', revenue_cents: 5000, customer_count: 5,
    distribution: flatAtFloor, skew_note: null
  }]), '');
  const html = page2.categoryMix();

  assert.ok(html.includes('Concentration'), 'at-floor (n=5) rows do get the concentration line');
  assert.ok(html.includes('SGD 10.00'), 'median (1000 cents) renders');
  assert.ok(html.includes('20.0%'), 'top1_share_bps (2000) formatted as 20.0%');
  assert.ok(!html.includes('overstates the typical customer'), 'no skew_note text when the server sent null');
  // No invented numbers: every figure traces to a payload field, nothing computed from anything
  // other than distribution.median / distribution.mean / distribution.top1_share_bps.
  assert.ok(!html.includes('mean_excl_top1'), 'mean_excl_top1 has no rendered surface (not required by the task)');
});

test('V704 category mix: a category with no distribution block renders nothing extra (older/absent payload shape)', () => {
  const page = makePage();
  page.setCategoryMix(bundleWith([{
    node_key: 'beauty.brows', label: 'Brows', revenue_cents: 3000, customer_count: 3
  }]), '');
  const html = page.categoryMix();
  assert.ok(!html.includes('Concentration'));
});

test('V704 category mix (check 98): the panel\'s existing RPC-error path is untouched by the new renderer', () => {
  const page = makePage();
  page.setCategoryMix(null, 'server error');
  const html = page.categoryMix();
  assert.ok(html.includes('What they buy could not load.'));
  assert.ok(html.includes('server error'));
  assert.ok(!html.includes('Concentration'));
});
