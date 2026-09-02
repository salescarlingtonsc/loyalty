/* NESTLY v679 — three more Customer Intelligence panels wired into customerIntelligencePage():
   funnelConversionPanelHtmlV679 (public.get_ci_funnel_conversion_v1, v673), demographicsPanelHtmlV679
   (public.get_ci_demographics_v1, v674) and behaviourPanelHtmlV679 (public.get_ci_daypart_v1, v675).

   Each renderer is a pure TOP-LEVEL function — same posture as recoveryReportHtmlV550
   (tests/business-ui/v550-recovery-report.test.mjs) — so these tests EXECUTE it against a fixture
   shaped exactly like the deployed RPC's own output (numbers lifted from the committed corpus
   truth tables: db/tests/executed/v673_corpus_funnels.sql, v674_corpus_demographics.sql,
   v675_corpus_behaviour.sql), never against a source-regex proxy for behaviour.

   The final test is a CONTRACT check in the tests/platform-console/v667-consultative-payload.test.mjs
   style: harvest the keys each renderer actually reads off its payload (from comment-stripped code)
   and require every one of them to appear in the corresponding migration's LIVE emitted-key set —
   the same defect class v667 guards (a renderer reading a key the SQL never emits, or renamed away
   from under it). Since v673/v674/v675 all embed the v672 statistical authority
   (app.rate_block_v1 / app.subgroup_evidence_v1) rather than reimplementing it, each migration's
   own emitted set is unioned with v672's for this check — the shared numerator/denominator/pct/n/
   floor/status vocabulary genuinely comes from there, not from the reader itself. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const v672 = readFileSync(join(root, 'db', 'migrations', '20260920_nestly_v672_statistical_authority.sql'), 'utf8');
const v673 = readFileSync(join(root, 'db', 'migrations', '20260920_nestly_v673_retention_funnels.sql'), 'utf8');
const v674 = readFileSync(join(root, 'db', 'migrations', '20260920_nestly_v674_demographic_intelligence.sql'), 'utf8');
const v675 = readFileSync(join(root, 'db', 'migrations', '20260920_nestly_v675_behaviour_service_package.sql'), 'utf8');

const blockStart = app.indexOf('function ciMeasuredSinceInlineV679(');
const blockEnd = app.indexOf('async function serviceMappingBoardPage(){', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart,
  'the v679 panels + shared helpers must be top-level functions before serviceMappingBoardPage');
const block = app.slice(blockStart, blockEnd);

function render(payload) {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    walletDate: (v) => `WD:${v}`,
    CUI: { icon: () => '', emptyState: ({ title, body }) => `<div class="empty"><b>${title}</b><p>${body}</p></div>` }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${block}\n__exports.funnel=funnelConversionPanelHtmlV679;` +
    `__exports.demographics=demographicsPanelHtmlV679;` +
    `__exports.behaviour=behaviourPanelHtmlV679;`,
    context
  );
  return context.__exports;
}

/* ==================================================================================================
   1. funnelConversionPanelHtmlV679 — public.get_ci_funnel_conversion_v1 (nestly_v673)
   ================================================================================================== */

/* Truth table lifted verbatim from db/tests/executed/v673_corpus_funnels.sql's main scenario
   (window_days=30): mature_first=6, stage_1_to_2 converts {m1,m2,m3,m4}=4 -> rate_block(4,6)=66.7%;
   stage_2_to_3 mature_second=4, converts {m1,m2}=2 -> rate_block(2,4)=50.0%; bottleneck='second_to_third'
   (50.0 < 66.7); immature.first_stage=1 (cl_immature), immature.second_stage=0. */
const FUNNEL_MAIN = {
  window_days: 30, time_basis: 'sale_occurred_at',
  stage_1_to_2: { numerator: 4, denominator: 6, pct: 66.7 },
  stage_2_to_3: { numerator: 2, denominator: 4, pct: 50.0 },
  immature: { first_stage: 1, second_stage: 0 },
  bottleneck: 'second_to_third',
  evidence: { n: 6, floor: 5, status: 'ok' },
  observed_since: '2026-08-01T00:00:00Z'
};

test('V679 funnel: the main scenario prints both stages with their counts and the weaker bottleneck', () => {
  const html = render(FUNNEL_MAIN).funnel(FUNNEL_MAIN);
  assert.ok(html.includes('4 of 6 returned (66.7%)'), 'stage 1->2 carries its own numerator/denominator');
  assert.ok(html.includes('2 of 4 returned (50.0%)'), 'stage 2->3 carries its own numerator/denominator');
  assert.ok(html.includes('Second to third visit'), 'the weaker stage is named as the bottleneck');
  assert.ok(html.includes('1 customer too recent to judge for the first stage'));
  assert.ok(html.includes('0 too recent for the second'));
  assert.ok(html.includes('WD:2026-08-01T00:00:00Z'), 'observed_since reaches the page');
  assert.ok(html.includes('30-day window'));
});

/* Small scenario from the same corpus file: stage_1_to_2=rate_block(0,3)=0/3/0.0% (counts present,
   not stripped, even though the rate is a real, computed zero); stage_2_to_3=rate_block(0,0)=0/0/null
   (nobody converted to a second visit at all); evidence n=3<floor 5 -> insufficient; bottleneck
   MUST be null even though the counts are real. */
const FUNNEL_SMALL = {
  window_days: 30, time_basis: 'sale_occurred_at',
  stage_1_to_2: { numerator: 0, denominator: 3, pct: 0.0 },
  stage_2_to_3: { numerator: 0, denominator: 0, pct: null },
  immature: { first_stage: 0, second_stage: 0 },
  bottleneck: null,
  evidence: { n: 3, floor: 5, status: 'insufficient' }
};

test('V679 funnel: a below-floor population keeps its real counts, including a genuine 0.0%', () => {
  const html = render(FUNNEL_SMALL).funnel(FUNNEL_SMALL);
  assert.ok(html.includes('0 of 3 returned (0.0%)'),
    'a real, computed zero rate is not the same thing as a withheld one and must still print');
  assert.ok(html.includes('No bottleneck can be named yet') || html.includes('Not enough data yet'),
    'insufficient evidence must withhold the bottleneck diagnosis, not merely a tied pct');
});

test('V679 funnel: a null pct never renders as 0.0% — it renders the not-enough-data idiom', () => {
  const nullPct = {
    window_days: 30, time_basis: 'sale_occurred_at',
    stage_1_to_2: { numerator: 0, denominator: 0, pct: null },
    stage_2_to_3: { numerator: 0, denominator: 0, pct: null },
    immature: { first_stage: 0, second_stage: 0 },
    bottleneck: null,
    evidence: { n: 0, floor: 5, status: 'insufficient' }
  };
  const html = render(nullPct).funnel(nullPct);
  assert.ok(html.includes('Not enough data yet'), 'the page idiom for a null pct must appear');
  assert.ok(!html.includes('0.0'), 'a null pct must never be dressed up as a measured 0.0%');
});

test('V679 funnel: a missing/malformed payload renders the empty state, not a crash', () => {
  const f = render(null).funnel;
  assert.ok(f(null).includes('Run this report to load the retention funnel.'));
  assert.doesNotThrow(() => f({}));
  assert.doesNotThrow(() => f(undefined));
});

/* ==================================================================================================
   2. demographicsPanelHtmlV679 — public.get_ci_demographics_v1 (nestly_v674)
   ================================================================================================== */

/* Truth table lifted verbatim from db/tests/executed/v674_corpus_demographics.sql's R1 block,
   window [today-30, today-20]: (25_30,female) cell customers=5 revenue_cents=75000 visits=5
   revenue_txns=4 -> atv_cents=75000/4=18750 exactly, evidence 'ok' (n=5>=floor 5); (31_40,male)
   cell customers=2 revenue_cents=12000 visits=2, evidence 'insufficient' (n=2<5) -> atv_cents
   NULLED while customers/revenue_cents/visits stay visible; unclassified customers=2
   revenue_cents=12000; active_customers=9, resolved_customers=7 -> coverage.demographics=7/9=77.8%;
   active_revenue_cents=99000, resolved_revenue_cents=87000 -> coverage.revenue=87000/99000=87.9%. */
const DEMOGRAPHICS_R1 = {
  time_basis: 'sale_occurred_at',
  cells: [
    { age_band: '25_30', gender: 'female', customers: 5, revenue_cents: 75000, visits: 5,
      atv_cents: 18750, evidence: { n: 5, floor: 5, status: 'ok' } },
    { age_band: '31_40', gender: 'male', customers: 2, revenue_cents: 12000, visits: 2,
      atv_cents: null, evidence: { n: 2, floor: 5, status: 'insufficient' } }
  ],
  unclassified: { customers: 2, revenue_cents: 12000 },
  coverage: {
    demographics: { numerator: 7, denominator: 9, pct: 77.8 },
    revenue: { numerator: 87000, denominator: 99000, pct: 87.9 }
  },
  observed_since: '2026-08-20T00:00:00Z'
};

test('V679 demographics: an evidence-ok cell shows its real ATV; a below-floor cell withholds ATV but keeps its counts', () => {
  const html = render(DEMOGRAPHICS_R1).demographics(DEMOGRAPHICS_R1);
  assert.ok(html.includes('SGD 187.50'), 'the ok cell’s ATV (75000/4=18750 cents) must print');
  assert.ok(html.includes('SGD 750.00'), 'the ok cell’s revenue must print beside it');
  assert.ok(html.includes('Female') && html.includes('25–30'));
  assert.ok(html.includes('Male') && html.includes('31–40'));
  assert.ok(html.includes('SGD 120.00'), 'the below-floor cell’s raw revenue (12000 cents) must still print');
  assert.ok(html.includes('>2<'), 'the below-floor cell’s raw customer count must still print');
  assert.ok(html.includes('Not enough data yet (fewer than 5)'), 'the below-floor ATV is withheld, not zeroed');
  assert.ok(!html.includes('SGD 60.00'),
    'the below-floor cell (12000 cents / 2 customers) must never show a fabricated per-customer average');
});

test('V679 demographics: coverage is rendered verbatim-style with its numerator and denominator', () => {
  const html = render(DEMOGRAPHICS_R1).demographics(DEMOGRAPHICS_R1);
  assert.ok(html.includes('Demographics known for 7 of 9 identified customers (77.8%)'));
});

test('V679 demographics: the unclassified bucket is always present', () => {
  const html = render(DEMOGRAPHICS_R1).demographics(DEMOGRAPHICS_R1);
  assert.ok(html.includes('Unclassified'));
  assert.ok(html.includes('SGD 120.00'));
});

test('V679 demographics: a null coverage pct renders the not-enough-data idiom, never 0.0%', () => {
  const payload = { ...DEMOGRAPHICS_R1, cells: [], unclassified: { customers: 0, revenue_cents: 0 },
    coverage: { demographics: { numerator: 0, denominator: 0, pct: null },
      revenue: { numerator: 0, denominator: 0, pct: null } } };
  const html = render(payload).demographics(payload);
  assert.ok(html.includes('Not enough data yet'));
  assert.ok(!html.includes('(0.0%)'));
});

test('V679 demographics: a missing/malformed payload renders the empty state, not a crash', () => {
  const d = render(null).demographics;
  assert.ok(d(null).includes('Run this report to load demographics.'));
  assert.doesNotThrow(() => d({}));
});

/* ==================================================================================================
   3. behaviourPanelHtmlV679 — public.get_ci_daypart_v1 (nestly_v675)
   ================================================================================================== */

/* Truth table lifted verbatim from db/tests/executed/v675_corpus_behaviour.sql PART A, a 14-day
   window so every ISO weekday occurs exactly twice: Monday visits=6 revenue_cents=12000
   revenue_per_visit_cents=2000 evidence 'ok' (n=6), weekday_occurrences=2,
   visits_per_occurrence=rate_block(6,2)=300.0%; Saturday visits=5 revenue_cents=45000
   revenue_per_visit_cents=9000 evidence 'ok' (n=5, AT the floor); Wednesday visits=2
   revenue_cents=100000 evidence 'insufficient' (n=2<5) -> revenue_per_visit_cents and
   visits_per_occurrence.pct MUST be null though visits/revenue stay visible; busiest_weekday=Monday
   (a raw count); most_valuable_weekday=Saturday (Wednesday's raw 50000/visit is 5x larger but is
   INELIGIBLE — not evidence-ok — this is the check-36 "distinguishable" assertion). */
const DAYPART_A = {
  time_basis: 'sale_occurred_at',
  basis_note: 'Bucketed on sale_occurred_at, till time not arrival time.',
  weekdays: [
    { dow: 1, label: 'Monday', visits: 6, revenue_cents: 12000, revenue_per_visit_cents: 2000,
      weekday_occurrences: 2, visits_per_occurrence: { numerator: 6, denominator: 2, pct: 300.0 },
      evidence: { n: 6, floor: 5, status: 'ok' } },
    { dow: 3, label: 'Wednesday', visits: 2, revenue_cents: 100000, revenue_per_visit_cents: null,
      weekday_occurrences: 2, visits_per_occurrence: { numerator: 2, denominator: 2, pct: null },
      evidence: { n: 2, floor: 5, status: 'insufficient' } },
    { dow: 6, label: 'Saturday', visits: 5, revenue_cents: 45000, revenue_per_visit_cents: 9000,
      weekday_occurrences: 2, visits_per_occurrence: { numerator: 5, denominator: 2, pct: 250.0 },
      evidence: { n: 5, floor: 5, status: 'ok' } }
  ],
  busiest_weekday: { dow: 1, label: 'Monday', visits: 6 },
  most_valuable_weekday: { dow: 6, label: 'Saturday', revenue_per_visit_cents: 9000 },
  observed_since: '2026-08-15T00:00:00Z'
};

test('V679 behaviour: busiest (a raw count) and most-valuable (evidence-gated) are reported separately', () => {
  const html = render(DAYPART_A).behaviour(DAYPART_A);
  assert.ok(html.includes('Monday') && html.includes('6 visits'), 'busiest names Monday by raw visit count');
  assert.ok(html.includes('Saturday') && html.includes('SGD 90.00 per visit'),
    'most-valuable names Saturday, not Wednesday, even though Wednesday’s raw figure is larger');
  assert.ok(!/most valuable[\s\S]{0,120}Wednesday/i.test(html),
    'a below-floor weekday must never win the most-valuable verdict on the strength of a big raw number');
});

test('V679 behaviour: a below-floor weekday keeps its counts visible but withholds revenue per visit', () => {
  const html = render(DAYPART_A).behaviour(DAYPART_A);
  assert.ok(html.includes('SGD 1000.00'), 'Wednesday’s raw revenue (100000 cents) must still print');
  assert.ok(html.includes('>2<'), 'Wednesday’s raw visit count must still print');
  assert.ok(html.includes('Not enough data yet (fewer than 5)'), 'Wednesday’s per-visit figure is withheld');
  assert.ok(!html.includes('SGD 500.00'), 'the withheld per-visit figure (100000/2=50000 cents) must never print');
});

test('V679 behaviour: an evidence-ok weekday shows its real revenue-per-visit and visited-on rate', () => {
  const html = render(DAYPART_A).behaviour(DAYPART_A);
  assert.ok(html.includes('SGD 20.00'), 'Monday revenue per visit (2000 cents)');
  assert.ok(html.includes('6 of 2 (300.0%)'), 'visits_per_occurrence carries its own counts');
  assert.ok(html.includes('SGD 90.00'), 'Saturday revenue per visit (9000 cents)');
});

test('V679 behaviour: basis_note is always rendered — the till-time honesty line', () => {
  const html = render(DAYPART_A).behaviour(DAYPART_A);
  assert.ok(html.includes('Bucketed on sale_occurred_at, till time not arrival time.'));
  const noNote = { ...DAYPART_A, basis_note: '' };
  assert.doesNotThrow(() => render(noNote).behaviour(noNote));
});

test('V679 behaviour: a missing/malformed payload renders the empty state, not a crash', () => {
  const b = render(null).behaviour;
  assert.ok(b(null).includes('Run this report to load weekday behaviour.'));
  assert.doesNotThrow(() => b({}));
});

/* ==================================================================================================
   4. Wiring: the three RPCs join the page's existing Promise.all, and a failed section withholds
      itself using the page's own ciQuietErrorV650 idiom (source-checked here; behaviourally the
      renderers above are what is EXECUTED — this just proves the call sites exist and use the
      established error idiom, matching how V550's wiring test checks call sites, not behaviour).
   ================================================================================================== */

test('V679 wiring: the three RPCs are called in the existing Promise.all with the top bar’s branch scope', () => {
  assert.ok(app.includes("sb.rpc('get_ci_funnel_conversion_v1',{"));
  assert.ok(app.includes("sb.rpc('get_ci_demographics_v1',{"));
  assert.ok(app.includes("sb.rpc('get_ci_daypart_v1',{"));
  assert.ok(app.includes('funnelConversionResponse,demographicsResponse,behaviourResponse'));
});

test('V679 wiring: each panel withholds itself on error using the page’s own ciQuietErrorV650 idiom', () => {
  assert.ok(app.includes("if(lastFunnelConversionError)return ciQuietErrorV650('Retention funnel could not load.',lastFunnelConversionError);"));
  assert.ok(app.includes("if(lastDemographicsError)return ciQuietErrorV650('Demographics could not load.',lastDemographicsError);"));
  assert.ok(app.includes("if(lastBehaviourError)return ciQuietErrorV650('When customers come in could not load.',lastBehaviourError);"));
  assert.ok(app.includes('${ciFunnelConversionMarkupV679()}${ciDemographicsMarkupV679()}${ciBehaviourMarkupV679()}'),
    'the three panels must actually be spliced into the page body');
});

/* ==================================================================================================
   5. CONTRACT: every payload key each renderer reads is one the corresponding LIVE SQL emits.
      Same defect class and same method as tests/platform-console/v667-consultative-payload.test.mjs
      "v667 CONTRACT" test: harvest keys from comment-stripped code, slice each migration down to
      its LAST (live) function definition, and require every harvested key to be in that emitted set.
   ================================================================================================== */

test('V679 CONTRACT: every payload key each renderer reads is one the LIVE SQL emits', () => {
  const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');

  const sliceFn = (label, start, end) => {
    const from = block.indexOf(start);
    assert.ok(from > -1, `missing renderer slice start: ${start}`);
    /* `block` was already cut at 'async function serviceMappingBoardPage(){' when it was
       extracted above, so that marker never appears inside `block` itself — the last slice
       runs to the end of `block`, not to another indexOf of that same marker. */
    const to = end === null ? block.length : block.indexOf(end, from + start.length);
    assert.ok(to > from, `missing renderer slice end: ${end}`);
    return stripComments(block.slice(from, to));
  };
  const helpers = sliceFn('helpers', 'function ciMeasuredSinceInlineV679(', 'function funnelConversionPanelHtmlV679(');
  const funnelCode = sliceFn('funnel', 'function funnelConversionPanelHtmlV679(', 'function demographicsPanelHtmlV679(');
  const demographicsCode = sliceFn('demographics', 'function demographicsPanelHtmlV679(', 'function behaviourPanelHtmlV679(');
  const behaviourCode = sliceFn('behaviour', 'function behaviourPanelHtmlV679(', null);

  /* The shared v672 rate-block/evidence vocabulary (numerator/denominator/pct via local var `b`;
     n/floor/status via local var `ev`) is read the same way in all three renderers, always via
     the shared ciRateBlockV679/ciEvidenceCaptionV679/ciEvidenceInsufficientV679 helpers. */
  const sharedKeys = [
    ...[...helpers.matchAll(/\bb\.([a-z0-9_]+)/g)].map((m) => m[1]),
    ...[...helpers.matchAll(/\bev\.([a-z0-9_]+)/g)].map((m) => m[1])
  ];

  const liveBody = (source, schema, fn) => {
    const header = `create or replace function ${schema}.${fn}(`;
    const start = source.lastIndexOf(header);
    assert.ok(start > -1, `${schema}.${fn} must be defined`);
    const terminators = ['$$;', '$function$;']
      .map((tok) => source.indexOf(tok, start)).filter((i) => i > start);
    assert.ok(terminators.length > 0, `unterminated body for ${fn}`);
    return source.slice(start, Math.min(...terminators));
  };
  const emittedKeys = (sql) => new Set([...sql.matchAll(/'([a-z0-9_]+)'\s*,/g)].map((m) => m[1]));

  const rateBlockBody = liveBody(v672, 'app', 'rate_block_v1');
  const evidenceBody = liveBody(v672, 'app', 'subgroup_evidence_v1');
  const v672Emitted = emittedKeys(rateBlockBody + evidenceBody);
  for (const key of sharedKeys) {
    assert.ok(v672Emitted.has(key),
      `the shared rate/evidence helpers read "${key}" but app.rate_block_v1/app.subgroup_evidence_v1 (v672) never emit it`);
  }

  const check = (label, code, migrationSql, schema, fn, extraLocals) => {
    const emitted = new Set([...emittedKeys(liveBody(migrationSql, schema, fn)), ...v672Emitted]);
    const reads = [
      ...[...code.matchAll(/\bp\.([a-z0-9_]+)/g)].map((m) => m[1]),
      ...extraLocals.flatMap((local) =>
        [...code.matchAll(new RegExp(`\\b${local}\\.([a-z0-9_]+)`, 'g'))].map((m) => m[1]))
    ];
    assert.ok(reads.length > 0, `${label}: the harvest found no reads — the extraction pattern is broken`);
    for (const key of reads) {
      assert.ok(emitted.has(key),
        `${label} reads "${key}" but public.${fn} (plus the shared v672 authority) never emits it — ` +
        'this is exactly how transaction_count / returning_rate_pct shipped in v667’s incident');
    }
  };

  check('funnelConversionPanelHtmlV679', funnelCode, v673, 'public', 'get_ci_funnel_conversion_v1',
    ['immature']);
  check('demographicsPanelHtmlV679', demographicsCode, v674, 'public', 'get_ci_demographics_v1',
    ['cell', 'unclassified', 'coverage']);
  check('behaviourPanelHtmlV679', behaviourCode, v675, 'public', 'get_ci_daypart_v1',
    ['weekday', 'busiest', 'mostValuable']);
});
