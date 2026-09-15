/* NESTLY v902 — Business Intelligence in plain words, plus the two sections the owner asked for.
 *
 * Owner ruling 2026-09-15: "the wordings are too profound, a layman could not understand — make it
 * easy to understand", and three questions the page did not answer: which product is most popular
 * with which crowd, how to reach more of that crowd, and what could be done to improve the
 * business.
 *
 * Nothing behind the page changed. No migration, no RPC, no threshold, no ranking, no permission,
 * no privacy rule and no calculation: every number the two new sections print was a server field
 * before it reached them, and both are pure functions of bundles #/customerintel already fetches.
 * So the whole of this file is executed against fixtures shaped like the real payloads — the same
 * posture as tests/business-ui/v892-business-intelligence.test.mjs, whose shapes these copy.
 *
 * Three rules are tested as rules rather than as style:
 *   · a renamed label reads in the new words AND no longer reads in the old ones;
 *   · the primary surface contains no analyst noun at all — the expanded scan below;
 *   · an idea is a suggestion about a fact the model already holds, never a prediction, and its
 *     control always has somewhere real to go.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

import { workspaceTemplateRuntime } from '../support/workspace-template-runtime.mjs';
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const START = '/* nestly_v892 — BUSINESS INTELLIGENCE';
const END = '/* nestly_v892 END —';
const from = app.indexOf(START);
assert.ok(from > -1, 'the Business Intelligence presentation layer must exist in app/app.js');
const to = app.indexOf(END, from);
assert.ok(to > from, 'it must close with its end marker');
const block = app.slice(from, to);

const NBSP = String.fromCharCode(160);
function sandbox(overrides = {}) {
/* nestly_v959: several sentences in the sliced region are named templates now, so the sandbox
     carries the REAL template runtime. A stub would let a missing key or a dropped value pass a
     test that claims to render production output. */
  const context = vm.createContext({
    ...workspaceTemplateRuntime('en'),
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}`,
    walletDate: (v) => `WD:${v}`,
    CUI: { icon: () => '<svg aria-hidden="true"></svg>' },
    S: { biz: { currency: 'SGD' }, myRole: 'owner' },
    RevenueTruthUI: {
      money: (cents, currency) => new Intl.NumberFormat('en-SG', {
        style: 'currency', currency: String(currency || 'SGD'), currencyDisplay: 'code',
        minimumFractionDigits: 2, maximumFractionDigits: 2
      }).format(Number(cents) / 100)
    },
    ownerBriefLinesV826: () => [],
    ...overrides
  });
  context.__exports = {};
  vm.runInContext(`${block}
    __exports.model=biModelV892;__exports.snapshot=biSnapshotHtmlV892;__exports.select=biSelectInsightsV892;
    __exports.insights=biInsightsHtmlV892;__exports.card=biInsightCardHtmlV892;__exports.explain=biExplainHtmlV892;
    __exports.evidence=biEvidenceHtmlV892;__exports.pulse=biPulseHtmlV892;__exports.health=biHealthHtmlV892;
    __exports.overnight=biOvernightStripHtmlV892;__exports.explore=biExploreHtmlV892;
    __exports.buys=biWhoBuysHtmlV902;__exports.buyRows=biWhoBuysRowsV902;
    __exports.ideas=biIdeasHtmlV902;__exports.ideaList=biIdeasV902;__exports.ideaCta=biIdeaCtaHtmlV902;
    __exports.wording=BI_WORDING_V892;__exports.ageWords=BI_AGE_WORDS_V902;`, context);
  return context.__exports;
}
const BI = sandbox();
const textOf = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
const plain = (html) => textOf(html).split(NBSP).join(' ');

/* ==================================================================================================
   Fixtures — the same payload shapes v892 and v774 already pin.
   ================================================================================================== */
const OK = { n: 5, floor: 5, status: 'ok' };
const LOW = { n: 1, floor: 5, status: 'insufficient' };
const TRUTH = { status: 'ok', totals: { known_revenue_minor: 668330, identified_revenue_minor: 656330 } };
const TRUTH_PREV = { status: 'ok', totals: { known_revenue_minor: 596723 } };
const LIFECYCLE = { status: 'ok', metrics: { transacting_identified_customers: 9, new_customers: 3 } };
const LIFECYCLE_PREV = { status: 'ok', metrics: { transacting_identified_customers: 8, new_customers: 2 } };
const CASH_GAP = {
  totals: {
    revenue_recorded_cents: 668330, collected_cents: 421429, outstanding_cents: 244500,
    sales_count: 24, sales_fully_paid: 16, sales_partly_paid: 2, sales_unpaid: 6,
    collected_share: { numerator: 421429, denominator: 668330, pct: 63.0 }
  },
  unlinked_payments: { count: 1, cents: 4500 }, refunds_cents: 0, names_visible: true,
  outstanding_by_customer: [{ client_id: 'c7', client_name: 'Gil Tan', sales: 1, outstanding_cents: 200000 }]
};
const ATTENTION = {
  rows: [{ client_id: 'c1', full_name: 'Siti Rahman', status: 'overdue', last_visit_days: 62, cadence_days: 21.4 }],
  summary: { due: 1, overdue: 2, slipping: 1, considered: 9, monthly_at_risk_cents: 12000 }
};
const CUSTOMERS = [
  { client_id: 'c1', full_name: 'Siti Rahman', net_revenue_cents: 357030, days_since_last_purchase: 62 },
  { client_id: 'c2', full_name: 'Wei Ling', net_revenue_cents: 180000, days_since_last_purchase: 18 },
  { client_id: 'c3', full_name: 'Kumar Rajan', net_revenue_cents: 34000, days_since_last_purchase: 3 }
];
const PACKAGES = [
  { client_id: 'c1', remaining: 3, status: 'active', plan_name_snapshot: '4x Facial', list_unit_cents_snapshot: 9000 },
  { client_id: 'c2', remaining: 3, status: 'active', plan_name_snapshot: '5x Spa', list_unit_cents_snapshot: 12000 }
];
const CONTACTABILITY_ITEM = {
  id: 'contactability_gap', rank: 1, rank_class: 'unquantified', domain: 'consent',
  pattern: 'Only 6 of 9 customers may be sent a business offer on the widest channel available.',
  action: { what: 'Ask for marketing permission at checkout.' },
  impact: { cents: null }, confidence: { n: 9, floor: 5, status: 'ok' },
  evidence: {
    source_rpc: 'public.get_ci_contactability_v1',
    refs: { business_offers: { customers: 9 }, best_channel: 'sms', best_channel_allowed: 6 }
  },
  evidence_class: 'DIRECT_FACT', limitation: 'Consent is not appetite.'
};
const RHYTHM = {
  weekdays: [
    { dow: 2, label: 'Tuesday', visits: 5, occurrences: 4, per_occurrence: 1.3, revenue_cents: 116900 },
    { dow: 5, label: 'Friday', visits: 1, occurrences: 4, per_occurrence: 0.3, revenue_cents: 9000 }
  ],
  busiest_weekdays: [{ dow: 2, label: 'Tuesday', visits: 5, occurrences: 4 }],
  slowest_weekdays: [{ dow: 5, label: 'Friday', visits: 1, occurrences: 4 }]
};
/* get_ci_demographic_totals_v1's own by_item, shaped exactly as v774 pins it. Five kinds of row:
   a till bookkeeping line with no catalogue id, both cells known, age only, gender only, and an
   item whose buyers told the business nothing at all. */
const BY_ITEM = [
  {
    item_id: null, item_name: 'Cart line', item_type: 'custom', revenue_cents: 999999, buyers: 12,
    buyers_known_gender: 12, buyers_known_age: 12,
    by_gender: [{ gender: 'female', buyers: 12, share_of_item_buyers: { numerator: 12, denominator: 12, pct: 100.0 }, evidence: OK }],
    by_age_band: [{ age_band: '25_30', buyers: 12, share_of_item_buyers: { numerator: 12, denominator: 12, pct: 100.0 }, evidence: OK }]
  },
  {
    item_id: 'svc_facial', item_name: 'Facial', item_type: 'service', revenue_cents: 141000, buyers: 6,
    buyers_known_gender: 6, buyers_known_age: 5,
    by_gender: [
      { gender: 'female', buyers: 5, revenue_cents: 120000, share_of_item_buyers: { numerator: 5, denominator: 6, pct: 83.3 }, evidence: OK },
      { gender: 'male', buyers: 1, revenue_cents: 21000, share_of_item_buyers: { numerator: 1, denominator: 6, pct: null }, evidence: LOW }
    ],
    by_age_band: [{ age_band: '25_30', buyers: 5, revenue_cents: 118000, share_of_item_buyers: { numerator: 5, denominator: 5, pct: 100.0 }, evidence: OK }]
  },
  {
    item_id: 'svc_massage', item_name: 'Massage', item_type: 'service', revenue_cents: 90000, buyers: 4,
    buyers_known_gender: 0, buyers_known_age: 4,
    by_gender: [],
    by_age_band: [{ age_band: '41_50', buyers: 3, revenue_cents: 70000, share_of_item_buyers: { numerator: 3, denominator: 4, pct: null }, evidence: LOW }]
  },
  {
    item_id: 'prd_shampoo', item_name: 'Shampoo', item_type: 'product', revenue_cents: 20000, buyers: 3,
    buyers_known_gender: 3, buyers_known_age: 0,
    by_gender: [{ gender: 'male', buyers: 2, revenue_cents: 14000, share_of_item_buyers: { numerator: 2, denominator: 3, pct: 66.7 }, evidence: OK }],
    by_age_band: []
  },
  {
    item_id: 'svc_trim', item_name: 'Trim', item_type: 'service', revenue_cents: 5000, buyers: 2,
    buyers_known_gender: 0, buyers_known_age: 0, by_gender: [], by_age_band: []
  },
  {
    item_id: 'svc_brow', item_name: 'Brow shaping', item_type: 'service', revenue_cents: 1200, buyers: 1,
    buyers_known_gender: 1, buyers_known_age: 0,
    by_gender: [{ gender: 'other', buyers: 1, share_of_item_buyers: { numerator: 1, denominator: 1, pct: 100.0 }, evidence: OK }],
    by_age_band: []
  }
];
const DEMOGRAPHICS = {
  population: { customers: 9, revenue_cents: 656330 },
  gender: [], age_bands: [],
  coverage: {
    gender_known: { numerator: 3, denominator: 9, pct: 33.3 },
    age_known: { numerator: 3, denominator: 9, pct: 33.3 }
  },
  by_item: BY_ITEM,
  item_share_note: 'share_of_item_buyers is measured against that item’s buyers whose gender or age is known.',
  evidence_class: 'DIRECT_FACT'
};
const BUNDLES = {
  currency: 'SGD', periodDays: 30, from: '2026-08-16', to: '2026-09-14',
  scope: { branchId: null, branchCode: null, branchName: null },
  truth: TRUTH, truthPrev: TRUTH_PREV, lifecycle: LIFECYCLE, lifecyclePrev: LIFECYCLE_PREV,
  cashGap: CASH_GAP, attention: ATTENTION, packages: PACKAGES, customers: CUSTOMERS,
  summary: { net_revenue_cents: 656330 },
  opportunities: { scope: { currency: 'SGD' }, ranked: [CONTACTABILITY_ITEM], report_sections: {} },
  rhythm: RHYTHM, demographics: DEMOGRAPHICS,
  categoryMix: { status: 'ok', coverage: { classified_pct_bps: 5680 } },
  contactability: { business_offers: { customers: 9, allowed_by_channel: { sms: 6, email: 4 } } },
  funnelConversion: { stage_1_to_2: { numerator: 3, denominator: 7, pct: 42.9 } },
  action: { allowed: false, title: '', finding: '', costMinor: null }
};
const model = (overrides = {}) => BI.model({ ...BUNDLES, ...overrides });
/* Everything an owner actually reads above Explore, in one string. */
const primaryHtml = (view) => [
  BI.snapshot(view), BI.insights(BI.select(view)), BI.buys(view), BI.pulse(view),
  BI.health(view), BI.ideas(view),
  sandbox({ ownerBriefLinesV826: () => [{ kind: 'plain', text: 'Last 7 days: SGD 1,240.00.' }] })
    .overnight({ data_status: 'ok', brief: { week: {} } })
].join('\n');

/* ==================================================================================================
   1. PART A — the renamed labels, each one in the new words and in none of the old ones.
   ================================================================================================== */
test('v902 wording: every renamed owner label reads in plain words, and the old form is gone', () => {
  const w = BI.wording;
  const renamed = [
    ['snapshot', 'How your business is doing', 'Business snapshot'],
    ['insights', '3 things to know', null],
    ['pulse', 'Your customers right now', 'Customer pulse'],
    ['health', 'Things to keep an eye on', 'Business health'],
    ['explore', 'Look deeper', 'Explore your business'],
    ['overnight', 'Last night’s summary · past 7 days', 'Last night’s brief · Last 7 days'],
    ['evidenceSummary', 'Why is Peekaa telling me this?', 'Why am I seeing this?'],
    ['explainNumbers', 'Where this number comes from', 'Where these numbers come from'],
    ['explainNext', 'What you can do', 'What to do next'],
    ['noComparison', 'Not enough history yet to compare.', 'No earlier period to compare yet.'],
    ['noInsight', 'Nothing worth flagging yet. Peekaa will tell you as soon as it spots something.',
      'No reliable recommendation yet — Peekaa will surface one once there is enough evidence.'],
    ['noTemplate', 'Open the full details', 'View this insight in detailed analysis']
  ];
  for (const [key, next, before] of renamed) {
    assert.equal(w[key], next, `${key} reads in the owner's words`);
    if (before) assert.notEqual(w[key], before, `${key} no longer reads in the analyst's`);
  }
  /* And none of the old strings survives anywhere in the layer. */
  for (const gone of renamed.map((row) => row[2]).filter(Boolean)) {
    assert.ok(!block.includes(gone), `"${gone}" is gone from the presentation layer`);
  }
});

test('v902 wording: the six card types keep their meaning and change their words', () => {
  const types = BI.wording.types;
  assert.equal(Object.keys(types).join(' '),
    'needs_attention customer_risk business_risk opportunity doing_well still_learning',
    'six types, unchanged — this pass renames, it does not re-classify');
  assert.equal(types.needs_attention.label, 'Needs attention');
  assert.equal(types.customer_risk.label, 'A customer may be leaving');
  assert.equal(types.business_risk.label, 'Too dependent on one thing');
  assert.equal(types.opportunity.label, 'Chance to grow');
  assert.equal(types.doing_well.label, 'Going well');
  assert.equal(types.still_learning.label, 'Still learning');
  for (const gone of ['Customer risk', 'Business risk', "label:'Opportunity'", "label:'Doing well'"]) {
    assert.ok(!block.includes(gone), `"${gone}" is gone`);
  }
});

test('v902 wording: the section headings on screen are the renamed ones', () => {
  const view = model();
  assert.ok(plain(BI.snapshot(view)).includes('How your business is doing'));
  assert.ok(plain(BI.pulse(view)).includes('Your customers right now'));
  assert.ok(plain(BI.health(view)).includes('Things to keep an eye on'));
  assert.ok(plain(BI.buys(view)).includes('Who buys what'));
  assert.ok(plain(BI.ideas(view)).includes('Ideas to try'));
  assert.ok(plain(BI.ideas(view)).includes(
    'Simple things you could do this week. Peekaa suggests these from your own numbers.'));
  assert.ok(plain(BI.explore([{ key: 'x', title: 'X', body: '<i>x</i>' }])).includes('Look deeper'));
  const strip = sandbox({ ownerBriefLinesV826: () => [{ kind: 'plain', text: 'Last 7 days: SGD 1,240.00.' }] })
    .overnight({ data_status: 'ok', brief: { week: {} } });
  assert.ok(plain(strip).includes('Last night’s summary · past 7 days'));
});

test('v902 wording: the health rows say what they mean', () => {
  const html = plain(BI.health(model()));
  assert.ok(html.includes('How much you rely on your top customers'), `reliance row, got: ${html}`);
  assert.ok(html.includes('Services sorted into categories'), 'category coverage row');
  assert.ok(html.includes('What you know about your customers'), 'profile coverage row');
  for (const gone of ['Customer concentration', 'Customer profiles']) {
    assert.ok(!html.includes(gone), `"${gone}" is gone`);
  }
  /* The facts behind the rows are untouched — only their labels changed. */
  assert.ok(html.includes('Top 3 customers = 87% of known revenue'));
  assert.ok(html.includes('56.8% of revenue is sorted into categories'));
  assert.ok(html.includes('Age known for 33%'));
});

test('v902 wording: the evidence sentences read as sentences, not as classes', () => {
  const view = model();
  const html = plain(BI.evidence(BI.select(view).find((card) => card.topic === 'contactability')));
  assert.ok(html.includes('This comes straight from your own sales records.'), `got: ${html}`);
  assert.ok(html.includes('Peekaa saw this 9 times. It waits for at least 5 before saying anything.'),
    `the sample floor reads as a sentence, got: ${html}`);
  for (const gone of ['Based directly on your recorded business data.',
    'Based on a pattern in your data, not a proven cause.',
    'Peekaa needs at least', 'observations']) {
    assert.ok(!html.includes(gone), `"${gone}" is gone from the evidence rows`);
  }
  assert.ok(block.includes('This is a pattern Peekaa noticed. It may not be the reason.'),
    'the association sentence is the plain one too');
});

test('v902 wording: the card templates lost their analyst nouns and kept every number', () => {
  /* nestly_v960: a named template now — the wording is pinned once where it is written. */
  assert.ok(block.includes('categoryMakesUpPercentOfSortedMoney'), 'categorised revenue is gone');
  assert.ok(!block.includes('categorised revenue'), 'and does not survive anywhere');
  assert.ok(block.includes('categoryBringsMoreMoneyPerVisitThan'), 'earns more per visit is gone');
  assert.ok(!block.includes('earns more per visit than'));
  /* The structured fields each template reads are untouched: the same server keys. */
  for (const field of ['top_share_bps', 'top_category', 'overdue_regulars', 'recoverable_cents',
    'gold_weekday', 'dead_weekday', 'busiest_weekday', 'best_channel_allowed', 'best_channel',
    'unused_sessions', 'stage_1_to_2', 'window_days', 'reminder_only_candidates_n',
    'within_cycle_pct', 'plan_name', 'service_name', 'repeat_rate', 'full_name', 'top1_share_bps']) {
    assert.ok(block.includes(field), `${field} is still what a template reads`);
  }
});

test('v902 wording: the Explore rows are renamed in the page that mounts them', () => {
  const start = app.indexOf('const biExplore=biExploreHtmlV892([');
  assert.ok(start > -1, 'the Explore wiring must exist');
  const wiring = app.slice(start, app.indexOf('const biCardsV901=biSelectInsightsV892', start));
  const rows = [
    ["title:'Money in and money owed'", "title:'Revenue & payments'"],
    ["title:'Do customers come back?'", "title:'Retention'"],
    ["title:'What sells'", null],
    ["hint:'Who gets customers coming back'", "hint:'Who brings customers back'"],
    ["title:'Where customers come from'", "title:'Acquisition'"],
    ["title:'From looking to booking'", "title:'Booking funnel'"],
    ["title:'Busy and quiet times'", "title:'Weekday & time-of-day behaviour'"],
    ["title:'Prepaid sessions'", "title:'Packages'"],
    ["title:'Compare your branches'", "title:'Branches'"],
    ["title:'Make Peekaa smarter'", "title:'Improve your insights'"],
    ["hint:'Information Peekaa is missing'", null],
    ["title:'How Peekaa works this out'", "title:'Evidence & methodology'"],
    ["title:'Questions and answers'", "title:'Ask my business'"]
  ];
  for (const [next, before] of rows) {
    assert.ok(wiring.includes(next), `${next} is on the page`);
    if (before) assert.ok(!wiring.includes(before), `${before} is gone`);
  }
  assert.ok(wiring.includes("title:'Staff'"), 'Staff keeps its name');
  assert.ok(!wiring.includes('&amp;'), 'no title is pre-escaped in the data');
});

/* ==================================================================================================
   2. PART A — the expanded banned-word scan.
   ================================================================================================== */
/* The rule is about words the owner READS, so the scan runs on the rendered TEXT: a class name or
   an Explore group key inside an attribute is machinery, not copy. Standalone words only —
   "concentrated" is not "concentration", and the ban is on the noun. */
const BANNED_V902 = ['categorised', 'concentration', 'acquisition', 'retention', 'funnel',
  'methodology', 'evidence class', 'observations', 'cohort', 'attribution'];
function scanPrimary(view, label) {
  const text = plain(primaryHtml(view));
  for (const word of BANNED_V902) {
    assert.ok(!new RegExp(`\\b${word}\\b`, 'i').test(text),
      `the primary surface must not say "${word}" (${label}): ${text.slice(0, 400)}`);
  }
  return text;
}

test('v902 plain words: not one analyst noun survives on the primary surface', () => {
  scanPrimary(model(), 'the loaded month');
  /* And with a payload that carries every one of the findings that used to speak analyst. */
  const loud = model({
    opportunities: {
      scope: { currency: 'SGD' },
      ranked: [
        CONTACTABILITY_ITEM,
        {
          id: 'category_concentration', rank_class: 'unquantified', domain: 'category_mix',
          pattern: '141000 cents of 168000 cents of classified revenue — 83.9% — comes from a single category (Facial).',
          concentration: { top1_share_bps: 3980 },
          evidence: { refs: { top_category: { node_key: 'facial', label: 'Facial', customer_count: 6 }, top_share_bps: 8393 } },
          confidence: { n: 6, floor: 5 }, evidence_class: 'DIRECT_FACT', impact: { cents: null }
        },
        {
          id: 'daypart_shift', rank_class: 'quantified', domain: 'rhythm',
          pattern: 'Tuesday yields 23400 cents per visit against Friday’s 9000.',
          evidence: { refs: { gold_weekday: { label: 'Tuesday' }, dead_weekday: { label: 'Friday' }, busiest_weekday: { label: 'Tuesday', visits: 5 } } },
          confidence: { n: 9, floor: 5 }, evidence_class: 'ASSOCIATION', impact: { cents: 12000 }
        },
        {
          id: 'funnel_bottleneck', rank_class: 'quantified', domain: 'retention',
          pattern: 'Stage 1→2 conversion is 42.9% against a 60% cohort benchmark.',
          evidence: { refs: { stage_1_to_2: { numerator: 3, denominator: 7, pct: 42.9 }, window_days: 60 } },
          confidence: { n: 7, floor: 5 }, evidence_class: 'ASSOCIATION', impact: { cents: null }
        }
      ],
      report_sections: { strengths: [], failures: ['category_concentration'] }
    }
  });
  scanPrimary(loud, 'every analyst finding at once');
  /* The still-learning fallback used to say "retention" out loud. */
  const learning = model({
    cashGap: null, attention: null, packages: [], rhythm: null, demographics: null,
    opportunities: { ranked: [], report_sections: {} },
    funnelConversion: { stage_1_to_2: { numerator: 1, denominator: 2, pct: null } }
  });
  const cards = BI.select(learning);
  assert.equal(cards[0].type, 'still_learning');
  scanPrimary(learning, 'the still-learning state');
});

test('v902 plain words: the surface still prints no hole as a number, and no machine token', () => {
  const states = [
    {}, { demographics: null }, { rhythm: null }, { opportunities: null },
    { truth: null, lifecycle: null, cashGap: null, attention: null, packages: [], customers: [], summary: null },
    { demographics: { coverage: {}, by_item: [] } },
    { demographics: { coverage: {}, by_item: [{ item_id: 'x', item_name: 'X' }] } }
  ];
  for (const overrides of states) {
    const html = primaryHtml(model(overrides));
    assert.ok(!/NaN|undefined/.test(html), `no machine hole for ${JSON.stringify(overrides).slice(0, 60)}`);
    assert.ok(!/\bnull\b/.test(plain(html)), 'no null in the text either');
    for (const token of ['item_id', 'item_type', 'by_age_band', 'by_gender', 'share_of_item_buyers',
      'age_band', '51_plus', '25_30', 'DIRECT_FACT', 'ASSOCIATION', 'bps']) {
      assert.ok(!plain(html).includes(token), `"${token}" must not reach the owner`);
    }
  }
});

/* ==================================================================================================
   3. PART B — Who buys what.
   ================================================================================================== */
test('v902 who buys what: a row with no catalogue item is dropped, not described', () => {
  const built = BI.buyRows(model());
  assert.equal(built.dropped, 1, 'the till bookkeeping line is dropped');
  assert.ok(!built.rows.some((row) => row.name === 'Cart line'), 'and never named');
  const html = plain(BI.buys(model()));
  assert.ok(!html.includes('Cart line'), 'nor rendered');
  /* It was the biggest row by revenue, so dropping it is not an accident of ranking. */
  assert.equal(built.rows[0].name, 'Facial', 'the first real product leads');
});

test('v902 who buys what: five products at most, ranked by the revenue the server sent', () => {
  const built = BI.buyRows(model());
  assert.equal(built.rows.length, 5, 'top five');
  assert.equal(built.rows.map((row) => row.name).join(' | '),
    'Facial | Massage | Shampoo | Trim | Brow shaping', 'in the server\'s own revenue order');
  const html = plain(BI.buys(model()));
  assert.ok(!html.includes('Brow shaping') || built.rows.length === 5);
  /* A sixth qualifying product does not get a row. */
  const wide = BI.buyRows(model({
    demographics: {
      ...DEMOGRAPHICS,
      by_item: [...BY_ITEM, { item_id: 'svc_x', item_name: 'Extra', revenue_cents: 1, buyers: 1, by_gender: [], by_age_band: [] }]
    }
  }));
  assert.equal(wide.rows.length, 5);
  assert.ok(!wide.rows.some((row) => row.name === 'Extra'));
});

test('v902 who buys what: the crowd sentence has four forms and no fifth', () => {
  const rows = BI.buyRows(model()).rows;
  const by = (name) => rows.find((row) => row.name === name);
  /* both known */
  assert.equal(by('Facial').crowd.sentence, 'Mostly women aged 25–30 · 5 of 6 buyers');
  assert.equal(by('Facial').crowd.words, 'women aged 25–30');
  /* age only */
  assert.ok(by('Massage').crowd.sentence.startsWith('Mostly aged 41–50'), by('Massage').crowd.sentence);
  assert.ok(!by('Massage').crowd.sentence.includes('women'), 'no gender is invented');
  /* gender only */
  assert.equal(by('Shampoo').crowd.sentence, 'Mostly men · 2 of 3 buyers');
  assert.ok(!/aged/.test(by('Shampoo').crowd.sentence), 'no age band is invented');
  /* neither */
  assert.equal(by('Trim').crowd.sentence, 'You don’t know who bought this yet.');
  assert.equal(by('Trim').crowd.known, false);
  /* "other" is a word the page has, so it renders as a word. */
  assert.equal(by('Brow shaping').crowd.sentence, 'Mostly other · 1 of 1 buyers');
});

test('v902 who buys what: a cell below the server\'s floor says so, in buyers', () => {
  const rows = BI.buyRows(model()).rows;
  const shaky = rows.find((row) => row.name === 'Massage');
  assert.equal(shaky.crowd.sentence,
    'Mostly aged 41–50 (only 3 of 4 buyers told you their details — too few to be sure)');
  assert.equal(shaky.crowd.sure, false);
  const sure = rows.find((row) => row.name === 'Facial');
  assert.ok(!sure.crowd.sentence.includes('too few to be sure'), 'an ok cell carries no apology');
  assert.ok(sure.crowd.sentence.includes('5 of 6 buyers'), 'it states the share in buyers instead');
  assert.equal(sure.crowd.sure, true);
  /* Fail closed: the sentence leans on both cells, so a short SECOND cell makes it unsure too. */
  const mixed = BI.buyRows(model({
    demographics: {
      ...DEMOGRAPHICS,
      by_item: [{
        item_id: 's', item_name: 'Mixed', revenue_cents: 1000, buyers: 6,
        by_gender: [{ gender: 'female', buyers: 5, share_of_item_buyers: { numerator: 5, denominator: 6, pct: 83.3 }, evidence: OK }],
        by_age_band: [{ age_band: 'under_20', buyers: 2, share_of_item_buyers: { numerator: 2, denominator: 3, pct: null }, evidence: LOW }]
      }]
    }
  })).rows[0];
  assert.equal(mixed.crowd.sure, false, 'one short cell makes the whole sentence unsure');
  assert.equal(mixed.crowd.sentence,
    'Mostly women aged under 20 (only 2 of 3 buyers told you their details — too few to be sure)');
});

test('v902 who buys what: every age band renders as words, never as its token', () => {
  const bands = { under_20: 'under 20', '20_24': '20–24', '25_30': '25–30', '31_40': '31–40', '41_50': '41–50', '51_plus': '51 and over' };
  for (const [token, word] of Object.entries(bands)) {
    const row = BI.buyRows(model({
      demographics: {
        ...DEMOGRAPHICS,
        by_item: [{
          item_id: 'b', item_name: 'Band', revenue_cents: 100, buyers: 5, by_gender: [],
          by_age_band: [{ age_band: token, buyers: 5, share_of_item_buyers: { numerator: 5, denominator: 5, pct: 100.0 }, evidence: OK }]
        }]
      }
    })).rows[0];
    assert.equal(row.crowd.sentence, `Mostly aged ${word} · 5 of 5 buyers`);
    assert.ok(!row.crowd.sentence.includes(token), `the token "${token}" never reaches the owner`);
  }
  /* A band this page has no word for is not ranked, so nothing is guessed and nothing leaks. */
  const unknown = BI.buyRows(model({
    demographics: {
      ...DEMOGRAPHICS,
      by_item: [{
        item_id: 'b', item_name: 'Band', revenue_cents: 100, buyers: 5, by_gender: [],
        by_age_band: [{ age_band: '90_plus', buyers: 5, share_of_item_buyers: { numerator: 5, denominator: 5, pct: 100.0 }, evidence: OK }]
      }]
    }
  })).rows[0];
  assert.equal(unknown.crowd.known, false);
  assert.ok(!unknown.crowd.sentence.includes('90_plus'));
});

test('v902 who buys what: the coverage line, the note, and no percentage the server withheld', () => {
  const html = BI.buys(model());
  const text = plain(html);
  assert.ok(text.includes('You know the age of 3 of 9 customers and the gender of 3 of 9.'),
    `the coverage line comes from coverage, got: ${text}`);
  assert.ok(text.includes('Peekaa can only match a crowd to a product when the customer’s age or gender is on file.'),
    'the note is shown while anything is dropped or unknown');
  /* Not one percentage: the server withheld some of them, and the counts say it better anyway. */
  assert.ok(!/%/.test(text), `no percentage at all on this section, got: ${text}`);
  /* Money is formatted, never printed as cents. */
  assert.ok(text.split(NBSP).join(' ').includes('SGD 1,410.00'), 'grouped money');
  for (const cents of ['141000', '90000', '20000', '999999']) {
    assert.ok(!text.includes(cents), `the raw cents ${cents} never reach the owner`);
  }
});

test('v902 who buys what: with everything known, nothing is apologised for', () => {
  const clean = model({
    demographics: {
      population: { customers: 4, revenue_cents: 1000 },
      coverage: { gender_known: { numerator: 4, denominator: 4, pct: 100.0 }, age_known: { numerator: 4, denominator: 4, pct: 100.0 } },
      by_item: [{
        item_id: 'only', item_name: 'Only', revenue_cents: 1000, buyers: 4,
        by_gender: [{ gender: 'female', buyers: 4, share_of_item_buyers: { numerator: 4, denominator: 4, pct: 100.0 }, evidence: OK }],
        by_age_band: [{ age_band: '31_40', buyers: 4, share_of_item_buyers: { numerator: 4, denominator: 4, pct: 100.0 }, evidence: OK }]
      }]
    }
  });
  const text = plain(BI.buys(clean));
  assert.ok(text.includes('Mostly women aged 31–40 · 4 of 4 buyers'));
  assert.ok(!text.includes('Peekaa can only match a crowd'), 'no note when nothing is missing');
  assert.ok(text.includes('You know the age of 4 of 4 customers and the gender of 4 of 4.'));
});

test('v902 who buys what: no readable item means no section at all', () => {
  assert.equal(BI.buys(model({ demographics: null })), '', 'no reader, no section');
  assert.equal(BI.buys(model({ demographics: { coverage: {}, by_item: [] } })), '', 'no rows, no section');
  assert.equal(BI.buys(model({
    demographics: { coverage: {}, by_item: [BY_ITEM[0]] }
  })), '', 'only bookkeeping rows is the same as no rows');
  assert.equal(BI.buys(null), '', 'and no model at all is not a crash');
  /* A coverage block the server did not send contributes no half-sentence. */
  const bare = plain(BI.buys(model({ demographics: { coverage: {}, by_item: [BY_ITEM[1]] } })));
  assert.ok(!bare.includes('You know the age of'), `no coverage line without coverage, got: ${bare}`);
  assert.ok(bare.includes('Mostly women aged 25–30'), 'the row itself still renders');
});

/* ==================================================================================================
   4. PART C — Ideas to try.
   ================================================================================================== */
/* The Explore groups this page actually mounts — read out of the page itself, so an idea can never
   point at a group that does not exist. */
const EXPLORE_KEYS = (() => {
  const start = app.indexOf('const biExplore=biExploreHtmlV892([');
  const wiring = app.slice(start, app.indexOf('const biCardsV901=biSelectInsightsV892', start));
  return new Set([...wiring.matchAll(/\{key:'([a-z]+)'/g)].map((match) => match[1]));
})();
const ROUTES_V902 = new Set(['#/custpackages', '#/grow/bringback', '#/clients', '#/servicemapping']);

test('v902 ideas: four at most, in the owner\'s priority order', () => {
  const ideas = BI.ideaList(model());
  assert.equal(ideas.length, 4, 'never more than four');
  /* The vm realm's Array is not this realm's, so the order is compared as text. */
  assert.equal(ideas.map((idea) => idea.text).join(' | '), [
    'Ask your best customers to bring a friend.',
    'Call the 2 customers who still have sessions left.',
    'Try an offer on your quiet day.',
    'Call the regulars who are overdue.'
  ].join(' | '));
  const html = plain(BI.ideas(model()));
  assert.ok(html.includes('Ideas to try'));
  assert.equal((BI.ideas(model()).match(/class="bi-idea"/g) || []).length, 4);
});

test('v902 ideas: every idea quotes a fact this model already holds', () => {
  const because = Object.fromEntries(BI.ideaList(model()).map((idea) => [idea.text, idea.because]));
  assert.equal(because['Ask your best customers to bring a friend.'],
    'Most Facial buyers are women aged 25–30.');
  assert.equal(because['Call the 2 customers who still have sessions left.'],
    '2 customers hold 6 unused sessions.');
  assert.equal(because['Try an offer on your quiet day.'], 'Friday is your quietest day.');
  assert.equal(because['Call the regulars who are overdue.'], '2 regulars are overdue their usual visit.');
  /* Every "Because" reaches the screen prefixed, once. */
  const html = plain(BI.ideas(model()));
  for (const line of Object.values(because)) {
    assert.ok(html.includes(`Because: ${line}`), `"${line}" is quoted on screen`);
  }
  /* And the facts are the model's own, not new arithmetic. */
  const view = model();
  assert.equal(view.quietWeekday.label, 'Friday', 'the quiet day is the server\'s slowest_weekdays[0]');
  assert.equal(view.packages.holders, 2);
  assert.equal(view.packages.sessions, 6);
  assert.equal(view.bringBack.overdue, 2);
  assert.equal(BI.buyRows(view).rows[0].crowd.words, 'women aged 25–30');
});

test('v902 ideas: the later candidates surface only once the earlier facts are gone', () => {
  const later = BI.ideaList(model({
    demographics: { coverage: { age_known: { numerator: 2, denominator: 9, pct: 22.2 }, gender_known: { numerator: 2, denominator: 9, pct: 22.2 } }, by_item: [] },
    packages: [], rhythm: { weekdays: [], busiest_weekdays: [], slowest_weekdays: [] },
    attention: { rows: [], summary: { due: 0, overdue: 0, slipping: 0 } }
  }));
  assert.equal(later.map((idea) => idea.text).join(' | '), [
    'Ask customers at checkout if you may contact them.',
    'Record birthday and gender when you add a customer.',
    'Sort the rest of your services into categories.'
  ].join(' | '));
  const because = Object.fromEntries(later.map((idea) => [idea.text, idea.because]));
  assert.equal(because['Ask customers at checkout if you may contact them.'],
    'Only 6 of 9 customers agreed to be contacted.');
  assert.equal(because['Record birthday and gender when you add a customer.'],
    'You know the age of only 2 of 9 customers.');
  assert.equal(because['Sort the rest of your services into categories.'],
    '56.8% of your money is sorted into categories.');
});

test('v902 ideas: an idea is absent whenever the fact behind it is', () => {
  const none = (overrides) => BI.ideaList(model(overrides)).map((idea) => idea.text);
  assert.ok(!none({ demographics: { coverage: {}, by_item: [] } })
    .includes('Ask your best customers to bring a friend.'), 'no crowd, no friend-referral idea');
  assert.ok(!none({ packages: [] })
    .some((text) => text.startsWith('Call the') && text.includes('sessions left')), 'no sessions, no call idea');
  assert.ok(!none({ rhythm: { weekdays: [], busiest_weekdays: [], slowest_weekdays: [] } })
    .includes('Try an offer on your quiet day.'), 'the server must name the quiet day itself');
  assert.ok(!none({ attention: { rows: [], summary: { overdue: 0 } } })
    .includes('Call the regulars who are overdue.'), 'nobody overdue, no bring-back idea');
  assert.ok(!none({ opportunities: { ranked: [], report_sections: {} }, packages: [], rhythm: null, attention: null, demographics: { coverage: {}, by_item: [] } })
    .includes('Ask customers at checkout if you may contact them.'),
  'the contactability numbers are the server\'s finding or nothing');
  /* Above the owner's two thresholds, the two coverage ideas do not appear. */
  assert.ok(!BI.ideaList(model({
    packages: [], rhythm: null, attention: null,
    opportunities: { ranked: [], report_sections: {} },
    demographics: { coverage: { age_known: { numerator: 8, denominator: 9, pct: 88.9 } }, by_item: [] },
    categoryMix: { coverage: { classified_pct_bps: 9500 } }
  })).length, 'nothing qualifies above both thresholds');
});

test('v902 ideas: nothing qualifying means no section at all', () => {
  const empty = model({
    packages: [], rhythm: null, attention: null, demographics: null, categoryMix: null,
    opportunities: { ranked: [], report_sections: {} }
  });
  assert.equal(BI.ideaList(empty).length, 0);
  assert.equal(BI.ideas(empty), '', 'the whole section is omitted, not rendered empty');
  assert.equal(BI.ideas(null), '', 'and no model at all is not a crash');
});

test('v902 ideas: every control is a real route or a real Explore group', () => {
  const seen = [];
  for (const overrides of [{}, { packages: [], rhythm: null, attention: null,
    demographics: { coverage: { age_known: { numerator: 2, denominator: 9, pct: 22.2 } }, by_item: [] } }]) {
    for (const idea of BI.ideaList(model(overrides))) seen.push(idea.cta);
  }
  assert.ok(seen.length >= 6, `every candidate was exercised, got ${seen.length}`);
  for (const cta of seen) {
    assert.ok(cta, 'an idea always offers somewhere to go');
    if (cta.kind === 'route') {
      assert.ok(ROUTES_V902.has(cta.href), `${cta.href} must be a route the router knows`);
    } else {
      assert.equal(cta.kind, 'section');
      assert.ok(EXPLORE_KEYS.has(cta.section),
        `"${cta.section}" must be a group this page actually mounts (${[...EXPLORE_KEYS].join(', ')})`);
    }
    assert.ok(cta.label, 'and says where it goes');
  }
  /* The markup: a route is a link, a section is a button carrying the group key — never a bare
     in-page anchor, which the hash router would read as a route. */
  const html = BI.ideas(model());
  assert.match(html, /<button type="button" class="btn ghost sm bi-idea-cta" data-bi-open-v892="services">/);
  assert.match(html, /<a class="btn ghost sm bi-idea-cta" href="#\/custpackages">/);
  assert.ok(!/href="#[a-zA-Z]/.test(html), 'no bare in-page anchor');
  for (const key of [...html.matchAll(/data-bi-open-v892="([^"]+)"/g)].map((match) => match[1])) {
    assert.ok(EXPLORE_KEYS.has(key), `the opener "${key}" names a real Explore group`);
  }
  assert.equal(BI.ideaCta(null), '', 'no CTA renders as nothing');
  assert.equal(BI.ideaCta({ kind: 'route', href: '', label: 'Go' }), '', 'a route with no href is not a dead link');
  assert.equal(BI.ideaCta({ kind: 'section', section: '', label: 'Go' }), '', 'nor is a section with no key');
});

test('v902 ideas: a suggestion never predicts, promises or guarantees a result', () => {
  const texts = [];
  for (const overrides of [{}, { packages: [], rhythm: null, attention: null,
    demographics: { coverage: { age_known: { numerator: 2, denominator: 9, pct: 22.2 } }, by_item: [] } }]) {
    for (const idea of BI.ideaList(model(overrides))) texts.push(`${idea.text} ${idea.because} ${idea.cta.label}`);
  }
  const forbidden = [/will increase/i, /guarantee/i, /boosts?\b/i, /will grow/i, /will bring/i,
    /you will/i, /expect(ed)? to/i, /\bproven\b/i, /\bup to \d/i];
  for (const text of texts) {
    for (const pattern of forbidden) {
      assert.ok(!pattern.test(text), `an idea must not predict a result: "${text}" matched ${pattern}`);
    }
  }
  assert.ok(texts.length >= 6, 'and every candidate was checked');
  /* The heading says these are suggestions from the owner's own numbers, not a forecast. */
  assert.equal(BI.wording.ideasHint,
    'Simple things you could do this week. Peekaa suggests these from your own numbers.');
});

/* ==================================================================================================
   5. The page itself — order, and the opener it binds.
   ================================================================================================== */
test('v902 page: the two sections take their place in the owner\'s reading order', () => {
  const start = app.indexOf('body.innerHTML=`${biSnapshotHtmlV892(biModel)}');
  assert.ok(start > -1, 'the primary paint must exist');
  const paint = app.slice(start, app.indexOf('`;', start));
  const order = ['biSnapshotHtmlV892', 'biInsightsHtmlV892', 'biWhoBuysHtmlV902', 'biPulseHtmlV892',
    'biHealthHtmlV892', 'biIdeasHtmlV902', 'nightlyBriefStripMarkupV892', 'biExplore'];
  let cursor = -1;
  for (const name of order) {
    const at = paint.indexOf(name);
    assert.ok(at > cursor, `${name} comes after the block before it`);
    cursor = at;
  }
  /* Neither section asks the backend anything: the page hands both the SAME model it already built. */
  assert.ok(paint.includes('biWhoBuysHtmlV902(biModel)') && paint.includes('biIdeasHtmlV902(biModel)'));
  assert.ok(!/sb\.rpc/.test(block), 'the presentation layer never calls a reader');
});

test('v902 page: an idea CTA whose Explore group is absent is removed, not left dead', () => {
  const start = app.indexOf("body.querySelectorAll('[data-bi-open-v892]')");
  assert.ok(start > -1, 'the opener binding must exist');
  const binding = app.slice(start, start + 520);
  assert.ok(binding.includes('data-bi-section-v892'), 'it looks the group up by the Explore key');
  assert.ok(binding.includes('button.remove()'), 'and removes a control with nowhere to go');
  assert.ok(binding.includes('group.open=true'), 'otherwise it opens the group');
});
