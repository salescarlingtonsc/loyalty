/* NESTLY v685 — Customer Intelligence surfaces (checks 2/19/79-consumer/92/98/99, JS half).
 *
 * Three groups of tests live here:
 *
 *  A. A live-key CONTRACT test (check 92) for the four v650-era panels — acquisitionMarkupV650,
 *     funnelMarkupV650, contactabilityMarkupV650, categoryMixMarkupV650 — against the LAST
 *     definitions of get_ci_acquisition_v1 / get_ci_funnel_v1 / get_ci_contactability_v1 /
 *     get_ci_category_mix_v1 across migration history (v650 superseded by v667; comment-stripped,
 *     last definition wins), same method as tests/platform-console/v667-consultative-payload.test.mjs
 *     and tests/business-ui/v679-ci-analyst-panels.test.mjs's own CONTRACT test.
 *
 *  B. Executing tests for the same four panels plus the new opportunitiesPanelHtmlV685 (check
 *     79-consumer): these four v650 renderers are closures inside customerIntelligencePage(), not
 *     top-level functions, so this file extracts the exact self-contained slice that defines them
 *     (state vars + helpers + the four render functions, none of the surrounding DOM-writing code)
 *     and runs it in a vm context, exposing setter/getter hooks so a fixture can drive the closures
 *     directly — the same "execute the real renderer" posture as v679's own tests, adapted for a
 *     closure rather than a top-level function.
 *
 *  C. Drill parity (check 19) for category mix: aggregate customer_count vs the drilled row count
 *     (or, below the k=5 small-cell floor, the suppressed cohort_size), and the panel's own
 *     "N customers · showing N" line.
 *
 *  D. Failure-state tests (check 98) for all five panels (error path renders an explicit
 *     unavailable message, never zeros/blank) plus a source-level check on the CI CSV export's
 *     already-existing failure handling (create_customer_intelligence_export_v83 /
 *     get_customer_intelligence_export_page_v83), which is closure-bound inside the same page and
 *     not independently callable, so its failure paths are verified the way v679's "wiring" test
 *     verifies closure-bound call sites: by asserting the exact rendered error strings are present
 *     in source, rather than by executing the click handler end to end.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const v650 = readFileSync(join(root, 'db', 'migrations', '20260831_nestly_v650_ci_read_layer.sql'), 'utf8');
const v667 = readFileSync(join(root, 'db', 'migrations', '20260901_nestly_v667_ci_access_boundaries.sql'), 'utf8');
const v637 = readFileSync(join(root, 'db', 'migrations', '20260830_nestly_v637_public_funnel_counters.sql'), 'utf8');
const v644 = readFileSync(join(root, 'db', 'migrations', '20260831_nestly_v644_can_contact_authority.sql'), 'utf8');

/* -------------------------------------------------------------------------------------------
   Extract the self-contained closure slice: state vars + helpers + the four v650 renderers,
   skipping the DOM-writing statements (routeMain.innerHTML=...) that sit between them on the
   real page. Two contiguous ranges, concatenated.
   ------------------------------------------------------------------------------------------- */
const stateStart = app.indexOf("let lastAcquisitionBundle=null,lastAcquisitionError=''");
const stateEnd = app.indexOf('const CUSTOMER_INTELLIGENCE_PAGE_SIZE=100;');
assert.ok(stateStart > -1 && stateEnd > stateStart, 'state-var slice anchors must exist');
const stateBlock = app.slice(stateStart, stateEnd + 'const CUSTOMER_INTELLIGENCE_PAGE_SIZE=100;'.length);

const rendererStart = app.indexOf("const scopeMoney=(cents,currency=S.biz.currency||'SGD')=>");
const rendererEnd = app.indexOf('function ciCategoryMixWrapV650(){', rendererStart);
assert.ok(rendererStart > -1 && rendererEnd > rendererStart, 'renderer slice anchors must exist');
const rendererBlock = app.slice(rendererStart, rendererEnd);

const closureBlock = stateBlock + '\n' + rendererBlock;

function makePage() {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    walletDate: (v) => `WD:${v}`,
    S: { biz: { currency: 'SGD' } }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    closureBlock +
    `\n__exports.acquisition=()=>acquisitionMarkupV650();` +
    `__exports.funnel=()=>funnelMarkupV650();` +
    `__exports.contactability=()=>contactabilityMarkupV650();` +
    `__exports.categoryMix=()=>categoryMixMarkupV650();` +
    `__exports.categoryCustomerRows=(nodeKey,expected)=>ciCategoryCustomersRowsMarkupV650(nodeKey,expected);` +
    `__exports.setAcquisition=(bundle,err)=>{lastAcquisitionBundle=bundle;lastAcquisitionError=err||'';};` +
    `__exports.setFunnel=(bundle,err)=>{lastFunnelBundle=bundle;lastFunnelError=err||'';};` +
    `__exports.setContactability=(bundle,err)=>{lastContactabilityBundle=bundle;lastContactabilityError=err||'';};` +
    `__exports.setCategoryMix=(bundle,err)=>{lastCategoryMixBundle=bundle;lastCategoryMixError=err||'';};` +
    `__exports.setCategoryCustomerCache=(nodeKey,cached)=>{categoryCustomersCacheV650.set(nodeKey,cached);};` +
    `__exports.expandNode=(nodeKey)=>{expandedCategoryNodesV650.add(nodeKey);};`,
    context
  );
  return context.__exports;
}

/* =================================================================================================
   A. CONTRACT: every payload key each v650 renderer reads is one the LIVE SQL emits.
   ================================================================================================= */

test('V685 CONTRACT: every payload key the four v650 renderers read is one the LIVE SQL emits', () => {
  const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');
  const code = stripComments(rendererBlock);

  const sliceFn = (start, end) => {
    const from = code.indexOf(start);
    assert.ok(from > -1, `missing renderer slice start: ${start}`);
    const to = end === null ? code.length : code.indexOf(end, from + start.length);
    assert.ok(to > from, `missing renderer slice end: ${end}`);
    return code.slice(from, to);
  };
  const acquisitionCode = sliceFn('function acquisitionMarkupV650(', 'function ciFunnelStepsMarkupV650(');
  const funnelCode = sliceFn('function funnelMarkupV650(', 'function ciContactabilityGroupMarkupV650(');
  const contactabilityCode = sliceFn('function contactabilityMarkupV650(', 'const CI_CATEGORY_MIX_READY_THRESHOLD_BPS_V650');
  const categoryMixCode = sliceFn('function categoryMixMarkupV650(', null);

  /* LIVE DEFINITIONS ONLY — the last `create or replace function public.<fn>(` in each file that
     defines it, exactly as tests/platform-console/v667-consultative-payload.test.mjs's own CONTRACT
     test does, since v650's original four readers were dropped and redefined (with an added
     p_branch parameter) by v667. */
  const liveBody = (source, qualifiedFn) => {
    const header = `create or replace function ${qualifiedFn}(`;
    const start = source.lastIndexOf(header);
    assert.ok(start > -1, `${qualifiedFn} must be defined`);
    const end = source.indexOf('$$;', start);
    assert.ok(end > start, `unterminated body for ${qualifiedFn}`);
    return source.slice(start, end);
  };
  const emittedKeys = (sql) => new Set([...sql.matchAll(/'([a-z0-9_]+)'\s*,/g)].map((m) => m[1]));

  /* get_ci_funnel_v1's own body only ever names 'funnel' and 'observed_since' literally — the
     nested join/booking step names (page_view/started/completed) are DATA (the `surface`/`step`
     columns of public_funnel_counters), not literal jsonb keys in the reader itself. Their real
     vocabulary is declared where the data is constrained: v637's CHECK (surface in (...)) /
     CHECK (step in (...)). Folding that into the emitted set here is the same move v679's test
     made unioning v672's shared rate/evidence vocabulary into each of its three readers' sets. */
  /* v637's CHECK (col in ('a','b','c')) list ends with a closing paren, not a comma, so the
     shared emittedKeys() helper (which looks for a trailing comma, matching a jsonb_build_object
     key) misses the LAST value in that list ('completed'). A second, wider pass here catches any
     quoted identifier immediately followed by ')' as well, scoped to this one file so it does not
     loosen the jsonb_build_object check used everywhere else. */
  const v637Vocabulary = new Set([
    ...emittedKeys(v637),
    ...[...v637.matchAll(/'([a-z0-9_]+)'\s*\)/g)].map((m) => m[1])
  ]);

  const acquisitionEmitted = emittedKeys(liveBody(v667, 'public.get_ci_acquisition_v1'));
  const funnelEmitted = new Set([...emittedKeys(liveBody(v667, 'public.get_ci_funnel_v1')), ...v637Vocabulary]);
  const contactabilityEmitted = new Set([
    ...emittedKeys(liveBody(v667, 'public.get_ci_contactability_v1')),
    ...emittedKeys(liveBody(v644, 'app.contactable_counts_v1'))
  ]);
  const categoryMixEmitted = emittedKeys(liveBody(v667, 'public.get_ci_category_mix_v1'));

  /* Sanity: v650's ORIGINAL (superseded) definitions must not leak in — they lack p_branch and
     are a different, dead body. If liveBody ever picked the wrong occurrence this would still
     pass by coincidence for identical key names, so this only guards against gross slice errors,
     not a silent no-op; the real guard is `lastIndexOf` always preferring the later file. */
  assert.ok(v650.includes('create or replace function public.get_ci_acquisition_v1(p_business uuid'),
    'v650 must still contain the superseded 3-arg signature this test is NOT reading from');

  const check = (label, code2, emitted, extraLocals) => {
    const reads = [
      ...[...code2.matchAll(/\bbundle\??\.\??([a-z0-9_]+)/g)].map((m) => m[1]),
      ...extraLocals.flatMap((local) =>
        [...code2.matchAll(new RegExp(`\\b${local}\\.([a-z0-9_]+)`, 'g'))].map((m) => m[1]))
    ];
    assert.ok(reads.length > 0, `${label}: the harvest found no reads — the extraction pattern is broken`);
    for (const key of reads) {
      assert.ok(emitted.has(key),
        `${label} reads "${key}" but the live SQL (and its constrained vocabulary) never emits it`);
    }
  };

  check('acquisitionMarkupV650', acquisitionCode, acquisitionEmitted, ['source']);
  check('funnelMarkupV650', funnelCode, funnelEmitted, ['join', 'booking']);
  check('contactabilityMarkupV650', contactabilityCode, contactabilityEmitted, ['group', 'channels']);
  check('categoryMixMarkupV650', categoryMixCode, categoryMixEmitted, ['coverage', 'category', 'l2', 'l3']);
});

/* =================================================================================================
   B. Executing tests for the four v650 panels (sanity + the D. failure-state assertions live
      alongside each, since the fixtures are identical).
   ================================================================================================= */

test('V685 acquisitionMarkupV650: renders sources with their own evidence and counts', () => {
  const page = makePage();
  page.setAcquisition({
    sources: [{ via: 'qr_join', evidence: 'first_touch', customers: 12, new_in_period: 4, repeat_customers: 3 }],
    observed_since: '2026-08-01T00:00:00Z'
  }, '');
  const html = page.acquisition();
  assert.ok(html.includes('Joined by QR'));
  assert.ok(html.includes('>12<') || html.includes('12'));
  assert.ok(html.includes('WD:2026-08-01T00:00:00Z'));
});

test('V685 acquisitionMarkupV650 (check 98): an RPC error renders the explicit unavailable message, not zeros', () => {
  const page = makePage();
  page.setAcquisition(null, 'some backend failure');
  const html = page.acquisition();
  assert.ok(html.includes('Where customers come from could not load.'));
  assert.ok(html.includes('some backend failure'));
  assert.ok(!/>0</.test(html), 'an error state must never render a zero-stuffed table');
});

test('V685 funnelMarkupV650: renders join and booking steps', () => {
  const page = makePage();
  page.setFunnel({
    funnel: { join: { page_view: 100, started: 40, completed: 10 }, booking: { page_view: 20, started: 8, completed: 3 } },
    observed_since: '2026-08-01T00:00:00Z'
  }, '');
  const html = page.funnel();
  assert.ok(html.includes('100') && html.includes('40') && html.includes('10'));
  assert.ok(html.includes('20') && html.includes('8') && html.includes('3'));
});

test('V685 funnelMarkupV650 (check 98): an RPC error renders the explicit unavailable message, not zeros', () => {
  const page = makePage();
  page.setFunnel(null, 'timeout');
  const html = page.funnel();
  assert.ok(html.includes('Join &amp; booking funnel could not load.'));
  assert.ok(html.includes('timeout'));
});

test('V685 contactabilityMarkupV650: renders both groups\' channel counts', () => {
  const page = makePage();
  page.setContactability({
    business_offers: { category: 'business_offers', customers: 42, allowed_by_channel: { whatsapp: 10, sms: 0, email: 2, push: 0, in_app: 0, call: 0 } },
    rewards_and_points: { category: 'rewards_and_points', customers: 42, allowed_by_channel: { whatsapp: 30, sms: 1, email: 5, push: 0, in_app: 0, call: 0 } },
    note: 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.'
  }, '');
  const html = page.contactability();
  assert.ok(html.includes('10 / 42'), 'business_offers WhatsApp count/denominator');
  assert.ok(html.includes('30 / 42'), 'rewards_and_points WhatsApp count/denominator');
  assert.ok(html.includes('nobody is grandfathered'));
});

test('V685 contactabilityMarkupV650 (check 98): an RPC error renders the explicit unavailable message, not zeros', () => {
  const page = makePage();
  page.setContactability(null, 'permission denied');
  const html = page.contactability();
  assert.ok(html.includes('Who you may contact could not load.'));
  assert.ok(html.includes('permission denied'));
});

test('V685 contactabilityMarkupV650: a missing/malformed payload renders the empty state, not a crash', () => {
  const page = makePage();
  page.setContactability(null, '');
  const html = page.contactability();
  assert.ok(html.includes('Run this report to load contactability.'));
});

test('V685 categoryMixMarkupV650 (check 98): an RPC error renders the explicit unavailable message, not zeros', () => {
  const page = makePage();
  page.setCategoryMix(null, 'server error');
  const html = page.categoryMix();
  assert.ok(html.includes('What they buy could not load.'));
  assert.ok(html.includes('server error'));
});

/* =================================================================================================
   C. Drill parity (check 19): aggregate customer_count vs the drilled rows / suppressed cohort_size.
   ================================================================================================= */

/* Truth table (synthetic, shaped exactly like get_ci_category_mix_v1 / get_ci_category_customers_v1):
   node 'beauty.facials' aggregate customer_count=12, drilled customers array has 12 rows -> full
   parity, "12 customers · showing 12". node 'beauty.nails' aggregate customer_count=3 (below the
   v667 k=5 small-cell floor) -> get_ci_category_customers_v1 returns customers=[] and
   suppressed={reason:'below_small_cell_floor',floor:5,cohort_size:3}; the panel must show
   "3 customers · showing 3" (the cohort_size, not 0) plus the suppression note, never
   "No customers in this category yet.", which would be indistinguishable from a genuinely empty
   category. */
const CATEGORY_MIX_PARITY = {
  status: 'ready',
  coverage: { classified_pct_bps: 9500, projected_share_bps: 0 },
  categories: [
    { node_key: 'beauty.facials', label: 'Facials', revenue_cents: 500000, customer_count: 12 },
    { node_key: 'beauty.nails', label: 'Nails', revenue_cents: 30000, customer_count: 3 }
  ],
  observed_since: '2026-08-01T00:00:00Z'
};

test('V685 category-mix drill parity: full parity shows "N customers · showing N"', () => {
  const page = makePage();
  page.setCategoryMix(CATEGORY_MIX_PARITY, '');
  page.expandNode('beauty.facials');
  const twelveCustomers = Array.from({ length: 12 }, (_, i) => ({
    client_id: `c${i}`, full_name: `Customer ${i}`, visits: 2, revenue_cents: 40000, last_visit: '2026-08-15'
  }));
  page.setCategoryCustomerCache('beauty.facials', { data: { customers: twelveCustomers, suppressed: null } });
  const html = page.categoryMix();
  assert.ok(html.includes('12 customers · showing 12'), 'full parity: aggregate count equals drilled row count');
});

test('V685 category-mix drill parity: a below-floor node shows the suppressed cohort_size, never 0, and the suppression note', () => {
  const page = makePage();
  page.setCategoryMix(CATEGORY_MIX_PARITY, '');
  page.expandNode('beauty.nails');
  page.setCategoryCustomerCache('beauty.nails', {
    data: {
      customers: [],
      suppressed: { reason: 'below_small_cell_floor', floor: 5, cohort_size: 3, note: 'Naming a cohort this small would identify its members.' }
    }
  });
  const html = page.categoryMix();
  assert.ok(html.includes('3 customers · showing 3'),
    'below the floor, "showing" must read the suppressed cohort_size, not the empty drilled array length');
  assert.ok(html.includes('Naming a cohort this small would identify its members.'));
  assert.ok(!html.includes('No customers in this category yet.'),
    'a suppressed cohort must never be indistinguishable from a genuinely empty category');
});

test('V685 category-mix drill parity: a genuinely empty category shows 0 · showing 0 and the empty message', () => {
  const page = makePage();
  const zeroMix = { ...CATEGORY_MIX_PARITY, categories: [{ node_key: 'beauty.empty', label: 'Empty', revenue_cents: 0, customer_count: 0 }] };
  page.setCategoryMix(zeroMix, '');
  page.expandNode('beauty.empty');
  page.setCategoryCustomerCache('beauty.empty', { data: { customers: [], suppressed: null } });
  const html = page.categoryMix();
  assert.ok(html.includes('0 customers · showing 0'));
  assert.ok(html.includes('No customers in this category yet.'));
});

/* =================================================================================================
   D (continued). opportunitiesPanelHtmlV685 — check 79-consumer. Top-level function, so it is
   imported/executed the same way v679's panels are: extract the block and run it directly.
   ================================================================================================= */

const oppStart = app.indexOf('function ciOpportunityConfidenceV685(');
const oppEnd = app.indexOf('/* nestly_v679 — Customer intelligence gets three more evidence-safe panels', oppStart);
assert.ok(oppStart > -1 && oppEnd > oppStart, 'opportunitiesPanelHtmlV685 and its helpers must be top-level functions');
const oppBlock = app.slice(oppStart, oppEnd);

function renderOpportunities(payload) {
  const esc = (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const sandbox = {
    esc,
    walletDate: (v) => `WD:${v}`,
    /* ciEmptyPanelV679 is the real app.js function, defined a little further down the same file
       (outside this block on purpose — see the oppEnd anchor above). Reproduced verbatim here
       rather than widening the slice, so this stays a faithful copy of production behaviour. */
    ciEmptyPanelV679: (headingId, eyebrow, title, message) => `<section class="revenue-truth-section" aria-labelledby="${headingId}">
      <div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">${esc(eyebrow)}</span>
      <h2 id="${headingId}">${esc(title)}</h2></div></div>
      <div class="empty">${esc(message)}</div></section>`
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(oppBlock + '\n__exports.render=opportunitiesPanelHtmlV685;', context);
  return context.__exports.render(payload);
}

/* Truth table lifted from db/tests/executed/v678_corpus_consultant_spine.sql's main scenario:
   EXAMINED=14, PROMOTED=10, exactly 10 ranked entries, rank 1 is data_quality_coverage in the
   'foundation' rank_class (it always outranks every 'quantified'/'unquantified' business
   candidate — check 30/76). Ranks 2..10 here are simplified stand-ins (real ids/pattern text
   omitted) but preserve the corpus's rank_class ordering and the 10-item count. */
function makeRankedItem(rank, id, rankClass, impactCents) {
  return {
    id, rank, rank_class: rankClass, domain: 'x',
    pattern: `Pattern for ${id}`,
    comparison: { kind: 'cross_segment', detail: 'detail' },
    impact: impactCents === null ? { cents: null, reason: 'no incremental model available' } : { cents: impactCents, reason: null },
    action: { who: 'the owner', what: 'do the thing', when: 'this week', channel: 'in_person_at_checkout' },
    evidence: { source_rpc: 'public.get_ci_x_v1', refs: {} },
    evidence_class: rankClass === 'foundation' ? 'DIRECT_FACT' : 'ASSOCIATION',
    confidence: { n: 12, floor: 5, status: 'ok' },
    limitation: `Limitation text for ${id}.`
  };
}
const OPPORTUNITIES_MAIN = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-08-31', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [
    makeRankedItem(1, 'data_quality_coverage', 'foundation', null),
    ...Array.from({ length: 8 }, (_, i) => makeRankedItem(i + 2, `quantified_${i}`, 'quantified', 10000 - i * 100)),
    makeRankedItem(10, 'gateway_followthrough:svcB', 'unquantified', null)
  ],
  abstentions: [],
  comparisons: { subgroups_examined: 14, subgroups_promoted: 10, note: 'Promoted findings were selected from the examined set.' },
  observed_since: '2026-08-01T00:00:00Z'
};

test('V685 opportunitiesPanelHtmlV685: exactly 10 ranked items render, and the foundation item ranks first', () => {
  const html = renderOpportunities(OPPORTUNITIES_MAIN);
  const rankMatches = [...html.matchAll(/data-rank-class="([a-z_]+)"/g)].map((m) => m[1]);
  assert.equal(rankMatches.length, 10, 'exactly 10 ranked items must render');
  assert.equal(rankMatches[0], 'foundation', 'the foundation-class candidate must render first');
  assert.ok(html.includes('Pattern for data_quality_coverage'));
});

test('V685 opportunitiesPanelHtmlV685: each item shows rank, action fields, impact, evidence_class, confidence and limitation', () => {
  const html = renderOpportunities(OPPORTUNITIES_MAIN);
  assert.ok(html.includes('the owner'), 'action.who');
  assert.ok(html.includes('do the thing'), 'action.what');
  assert.ok(html.includes('this week'), 'action.when');
  assert.ok(html.includes('in_person_at_checkout'), 'action.channel');
  assert.ok(html.includes('SGD 100.00'), 'a quantified impact renders as currency (10000 cents)');
  assert.ok(html.includes('no incremental model available'), 'an unavailable impact renders its reason text, never blank');
  assert.ok(html.includes('DIRECT_FACT') && html.includes('ASSOCIATION'), 'evidence_class badges render');
  assert.ok(html.includes('12/5'), 'confidence renders as n/floor');
  assert.ok(html.includes('Limitation text for data_quality_coverage.'));
});

test('V685 opportunitiesPanelHtmlV685: the comparisons line reads "N examined · M promoted"', () => {
  const html = renderOpportunities(OPPORTUNITIES_MAIN);
  assert.ok(html.includes('14 examined · 10 promoted'));
});

const OPPORTUNITIES_DO_NOTHING = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-08-31', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [{
    id: 'do_nothing', rank: 1, rank_class: 'do_nothing', domain: 'none',
    pattern: 'No opportunity clears the evidence bar',
    comparison: { kind: 'threshold', detail: 'all 8 candidate evaluation(s) were made and every one abstained' },
    impact: { cents: null, reason: 'nothing is being recommended, so there is nothing to value' },
    action: { who: 'the consultant', what: 'Take no action from this analysis.', when: 'revisit at the next review', channel: 'none' },
    evidence: { source_rpc: 'public.get_ci_funnel_conversion_v1, ...', refs: { candidates_examined: 8, candidates_promoted: 0, abstentions: [] } },
    evidence_class: 'DIRECT_FACT',
    confidence: { n: 0, floor: 5, status: 'insufficient' },
    limitation: '"No opportunity" is a statement about what this period\'s data can support, not a finding that the business has none.'
  }],
  abstentions: [],
  comparisons: { subgroups_examined: 8, subgroups_promoted: 0, note: 'Promoted findings were selected from the examined set.' },
  observed_since: '2026-08-01T00:00:00Z'
};

test('V685 opportunitiesPanelHtmlV685: the do_nothing outcome renders its message as a first-class ranked entry, never hidden', () => {
  const html = renderOpportunities(OPPORTUNITIES_DO_NOTHING);
  assert.ok(html.includes('No opportunity clears the evidence bar'));
  assert.ok(html.includes('Take no action from this analysis.'));
  assert.ok(html.includes('nothing is being recommended, so there is nothing to value'));
  assert.ok(html.includes('8 examined · 0 promoted'));
  const rankMatches = [...html.matchAll(/data-rank-class="([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rankMatches, ['do_nothing']);
});

test('V685 opportunitiesPanelHtmlV685 (check 98): an RPC error renders the explicit unavailable message, not zeros/blank', () => {
  const html = renderOpportunities({ error: { message: 'evidence engine timed out' } });
  assert.ok(html.includes('Opportunities could not load'));
  assert.ok(html.includes('evidence engine timed out'));
});

test('V685 opportunitiesPanelHtmlV685: a missing/malformed payload renders the empty state, not a crash', () => {
  assert.ok(renderOpportunities(null).includes('Run this report to load ranked opportunities.'));
  assert.doesNotThrow(() => renderOpportunities({}));
  assert.ok(renderOpportunities({ ranked: [] }).includes('No ranked opportunities were returned for this scope.'));
});

/* -------------------------------------------------------------------------------------------
   Wiring: opportunitiesPanelHtmlV685 joins the page's existing Promise.all and quiet-error idiom,
   the same source-checked posture v679's own wiring test uses for its three panels.
   ------------------------------------------------------------------------------------------- */

test('V685 wiring: get_ci_opportunities_v1 is called in the existing Promise.all and spliced into the page', () => {
  assert.ok(app.includes("sb.rpc('get_ci_opportunities_v1',{"));
  assert.ok(app.includes('behaviourResponse,opportunitiesResponse'));
  assert.ok(app.includes("if(lastOpportunitiesError)return ciQuietErrorV650('Ranked opportunities could not load.',lastOpportunitiesError);"));
  assert.ok(app.includes('${ciBehaviourMarkupV679()}${ciOpportunitiesMarkupV685()}'),
    'the opportunities panel must actually be spliced into the page body');
});

/* =================================================================================================
   D (continued). The CI CSV export's existing failure handling (check 98) — closure-bound inside
   customerIntelligencePage, not independently callable; verified at the source level, the same way
   v679's wiring test verifies other closure-bound call sites.
   ================================================================================================= */

test('V685 CI CSV export: every failure path renders an explicit message, never a silent/blank failure', () => {
  const exportStart = app.indexOf("$('ciCsv').onclick=async()=>{");
  const exportEnd = app.indexOf('renderReportScopeNoteV272(isCurrent);', exportStart);
  assert.ok(exportStart > -1 && exportEnd > exportStart, 'the CI CSV export click handler must exist on this page');
  const exportCode = app.slice(exportStart, exportEnd);
  assert.ok(exportCode.includes('Complete export could not be created. No partial CSV was downloaded.'),
    'create_customer_intelligence_export_v83 failure must render an explicit message');
  assert.ok(exportCode.includes('Complete export stopped before downloading. No partial CSV was downloaded.'),
    'get_customer_intelligence_export_page_v83 failure must render an explicit message');
  assert.ok(exportCode.includes('Complete export could not prove a safe next page. No partial CSV was downloaded.'),
    'an unsafe pagination cursor must render an explicit message rather than silently stopping');
  assert.ok(exportCode.includes('exactSnapshotMismatch'),
    'a customer-count mismatch against the fixed snapshot must render an explicit message');
});
