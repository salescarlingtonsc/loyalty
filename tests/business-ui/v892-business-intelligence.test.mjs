/* NESTLY v892 — Business Intelligence: the model, the selector and every renderer.
 *
 * The whole v892 surface is built from pure top-level functions for the reason ownerBriefHtmlV771
 * is: a judgement that can be executed against a fixture is a judgement that can be proved. The
 * fixtures below are shaped like the payloads production actually emits — get_revenue_truth_v106,
 * get_customer_lifecycle_v107, get_ci_cash_gap_v1, get_attention_list_v548, client_packages,
 * get_ci_opportunities_v1, get_ci_visit_rhythm_v1, get_ci_demographic_totals_v1,
 * get_ci_category_mix_v1 and get_ci_funnel_conversion_v1 — transcribed from the shapes already
 * pinned in tests/business-ui/v771-owner-brief.test.mjs and v774-owner-brief-readers.test.mjs.
 *
 * Three owner rules are tested as rules rather than as style:
 *   · a KPI is a named server field, never an arithmetic of this page's own;
 *   · a strength is never dressed up as a task, and a coverage defect never takes one of the
 *     three slots;
 *   · the primary surface speaks the owner's language — no machine vocabulary, no raw generator
 *     ids, no zero standing in for something Peekaa does not know.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const START = '/* nestly_v892 — BUSINESS INTELLIGENCE';
const END = '/* nestly_v892 END —';
const from = app.indexOf(START);
assert.ok(from > -1, 'the v892 presentation layer must exist in app/app.js');
const to = app.indexOf(END, from);
assert.ok(to > from, 'the v892 presentation layer must close with its end marker');
const block = app.slice(from, to);

/* The names the layer is allowed to reach for. A sixth would fail here with a ReferenceError
   rather than quietly testing a different function. RevenueTruthUI.money is the real thing —
   grouped en-SG currency — because the owner asked for that exact format. */
const NBSP = String.fromCharCode(160);
function sandbox(overrides = {}) {
  const context = vm.createContext({
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
    __exports.card=biInsightCardHtmlV892;__exports.evidence=biEvidenceHtmlV892;__exports.insights=biInsightsHtmlV892;
    __exports.pulse=biPulseHtmlV892;__exports.health=biHealthHtmlV892;__exports.overnight=biOvernightStripHtmlV892;
    __exports.explore=biExploreHtmlV892;__exports.wording=BI_WORDING_V892;`, context);
  return context.__exports;
}
const BI = sandbox();
const textOf = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
const plain = (html) => textOf(html).split(NBSP).join(' ');
/* Intl's currency formatter separates the code from the amount with a non-breaking space, which
   is right on screen and invisible in an assertion. Normalise it rather than pinning the byte. */
const spaced = (value) => String(value).split(NBSP).join(' ');

/* ==================================================================================================
   Fixtures.
   ================================================================================================== */
const TRUTH = {
  status: 'ok',
  scope: { period: { from: '2026-08-16', to: '2026-09-14' }, currency: 'SGD', branch_id: null },
  totals: {
    known_revenue_minor: 668330, identified_revenue_minor: 656330, anonymous_revenue_minor: 12000,
    completed_transactions: 47
  }
};
const TRUTH_PREV = { status: 'ok', totals: { known_revenue_minor: 596723 } };
const LIFECYCLE = {
  status: 'ok',
  metrics: { new_customers: 3, reactivated_customers: 0, repeat_purchasers_in_period: 4, transacting_identified_customers: 9 }
};
const LIFECYCLE_PREV = { status: 'ok', metrics: { new_customers: 2, transacting_identified_customers: 8 } };
const CASH_GAP = {
  totals: {
    revenue_recorded_cents: 668330, collected_cents: 421429, outstanding_cents: 244500,
    sales_count: 24, sales_fully_paid: 16, sales_partly_paid: 2, sales_unpaid: 6,
    collected_share: { numerator: 421429, denominator: 668330, pct: 63.0 }
  },
  by_method: [{ method: 'card', cents: 240000, payments: 4 }],
  refunds_cents: 0,
  unlinked_payments: { count: 1, cents: 4500 },
  outstanding_by_customer: [{ client_id: 'c7', client_name: 'ZZ Gil', sales: 1, outstanding_cents: 200000 }],
  names_visible: true,
  time_basis: 'sale_occurred_at',
  evidence_class: 'DIRECT_FACT'
};
const ATTENTION = {
  rows: [
    { client_id: 'c1', full_name: 'Siti Rahman', phone: '81863833', status: 'overdue', last_visit_days: 62, cadence_days: 21.4, monthly_value_cents: 12000 },
    { client_id: 'c2', full_name: 'Wei Ling', phone: null, status: 'due', last_visit_days: 18, cadence_days: 17.6, monthly_value_cents: 8000 }
  ],
  summary: { due: 1, overdue: 1, slipping: 1, considered: 9, one_time_count: 2, monthly_at_risk_cents: 12000 }
};
const CUSTOMERS = [
  { client_id: 'c1', full_name: 'Siti Rahman', net_revenue_cents: 357030, days_since_last_purchase: 62, visit_count: 18 },
  { client_id: 'c2', full_name: 'Wei Ling', net_revenue_cents: 180000, days_since_last_purchase: 18, visit_count: 7 },
  { client_id: 'c3', full_name: 'Kumar', net_revenue_cents: 34000, days_since_last_purchase: 3, visit_count: 2 },
  { client_id: 'c4', full_name: 'Nobody', net_revenue_cents: 0, days_since_last_purchase: null, visit_count: 0 }
];
const SUMMARY = { known_customers: 11, net_revenue_cents: 656330, cash_collected_cents: 411830 };
const PACKAGES = [
  { id: 'p1', client_id: 'c1', remaining: 3, sessions_snapshot: 4, status: 'active', plan_name_snapshot: '4x Facial', list_unit_cents_snapshot: 9000 },
  { id: 'p2', client_id: 'c2', remaining: 3, sessions_snapshot: 5, status: 'active', plan_name_snapshot: '5x Spa', list_unit_cents_snapshot: 12000 }
];
const FOUNDATION_ITEM = {
  id: 'coverage_defect', rank: 1, rank_class: 'foundation', domain: 'coverage',
  pattern: 'Only 56.8% of revenue is sorted into categories, and 33% of customers have an age on file.',
  action: { who: 'the owner', what: 'Map every service and product to a category in Settings.', when: 'before the next review', channel: 'settings_and_checkout' },
  impact: { cents: null }, confidence: { n: 24, floor: 5, status: 'ok' },
  evidence_class: 'DIRECT_FACT', limitation: 'Coverage is not accuracy.'
};
const LEAKAGE_ITEM = {
  id: 'package_leakage:plan_small', rank: 2, rank_class: 'quantified', domain: 'packages',
  pattern: 'Six prepaid facial packages have sessions left that nobody has booked.',
  action: { who: 'front desk', what: 'Call the six holders and book their remaining sessions.', when: 'this week', channel: 'in_app' },
  impact: { cents: 54000 }, confidence: { n: 9, floor: 5, status: 'ok' },
  evidence_class: 'DIRECT_FACT', limitation: 'It cannot see a session booked outside Peekaa.',
  reversal_condition: 'Peekaa drops this once the remaining sessions are booked.'
};
const STRENGTH_ITEM = {
  id: 'strength:category:facial', rank: 3, rank_class: 'strength', domain: 'category_mix',
  pattern: 'Facials bring in more revenue per customer than anything else you sell.',
  action: { who: 'nobody', what: '', when: '', channel: '' },
  impact: { cents: null }, confidence: { n: 12, floor: 5, status: 'ok' },
  evidence_class: 'ASSOCIATION', limitation: 'It says nothing about why.'
};
const OPPORTUNITIES = {
  scope: { currency: 'SGD' },
  ranked: [FOUNDATION_ITEM, LEAKAGE_ITEM, STRENGTH_ITEM],
  report_sections: {
    strengths: ['strength:category:facial'], failures: [], leakage: ['package_leakage:plan_small'],
    margin: { status: 'unavailable', reason: 'no cost-of-goods field' },
    unnoticed_behaviour: [], segments: [], change: []
  },
  comparisons: { subgroups_examined: 31, subgroups_promoted: 2 },
  abstentions: [{ generator: 'lapsed_regulars', reason: 'no customer is overdue against a rhythm of their own' }]
};
const RHYTHM = {
  weekdays: [
    { dow: 2, label: 'Tuesday', visits: 5, occurrences: 4, per_occurrence: 1.3, revenue_cents: 116900 },
    { dow: 3, label: 'Wednesday', visits: 2, occurrences: 4, per_occurrence: 0.5, revenue_cents: 21000 }
  ],
  busiest_weekdays: [{ dow: 2, label: 'Tuesday', visits: 5, occurrences: 4, per_occurrence: 1.3 }],
  slowest_weekdays: [{ dow: 3, label: 'Wednesday', visits: 2, occurrences: 4, per_occurrence: 0.5 }],
  hour_blocks: [], coverage: {}, time_basis: 'sale_occurred_at'
};
const DEMOGRAPHIC_TOTALS = {
  population: { customers: 9, revenue_cents: 656330 },
  coverage: {
    gender_known: { numerator: 3, denominator: 9, pct: 33.3 },
    age_known: { numerator: 3, denominator: 9, pct: 33.3 }
  },
  gender: [], age_bands: [], by_item: []
};
const CATEGORY_MIX = { status: 'ok', coverage: { classified_pct_bps: 5680, projected_share_bps: 0 }, categories: [] };
const FUNNEL_CONVERSION = {
  window_days: 60, stage_1_to_2: { numerator: 3, denominator: 7, pct: 42.9 },
  stage_2_to_3: { numerator: 2, denominator: 5, pct: null }, immature: { first_stage: 2, second_stage: 1 },
  bottleneck: 'first_to_second', evidence: { n: 7, floor: 5, status: 'ok' }, time_basis: 'sale_occurred_at'
};
const CONTACTABILITY = {
  business_offers: { customers: 9, allowed_by_channel: { sms: 6, email: 4, push: 0, in_app: 9, call: 2 } },
  rewards_and_points: { customers: 9, allowed_by_channel: { sms: 6, email: 4 } }
};

const BUNDLES = {
  currency: 'SGD', periodDays: 30, from: '2026-08-16', to: '2026-09-14',
  scope: { branchId: null, branchCode: null, branchName: null, companySlug: 'cubbly', companyName: 'Cubbly SPA' },
  truth: TRUTH, truthPrev: TRUTH_PREV, lifecycle: LIFECYCLE, lifecyclePrev: LIFECYCLE_PREV,
  cashGap: CASH_GAP, attention: ATTENTION, packages: PACKAGES, customers: CUSTOMERS, summary: SUMMARY,
  opportunities: OPPORTUNITIES, rhythm: RHYTHM, demographics: DEMOGRAPHIC_TOTALS,
  categoryMix: CATEGORY_MIX, funnelConversion: FUNNEL_CONVERSION, contactability: CONTACTABILITY,
  action: { allowed: false, title: '', finding: '', costMinor: null }
};
const model = (overrides = {}) => BI.model({ ...BUNDLES, ...overrides });

/* ==================================================================================================
   1. The snapshot — four numbers, each one a named server field.
   ================================================================================================== */
test('v892 snapshot: every KPI is the server\'s own field, formatted as grouped currency', () => {
  const view = model();
  assert.equal(view.revenue.now, TRUTH.totals.known_revenue_minor, 'Revenue is known_revenue_minor');
  assert.equal(view.collected.now, CASH_GAP.totals.collected_cents, 'Collected is collected_cents');
  assert.equal(view.customers.now, LIFECYCLE.metrics.transacting_identified_customers);
  assert.equal(view.newCustomers.now, LIFECYCLE.metrics.new_customers);
  const html = plain(BI.snapshot(view));
  assert.ok(html.includes('SGD 6,683.30'), `grouped revenue, got: ${html}`);
  assert.ok(html.includes('SGD 4,214.29'), 'grouped collected');
  assert.ok(html.includes('63% collected'), 'the collected share comes from collected_share.pct');
  assert.ok(html.includes('3 new'), 'the customers tile carries new_customers as its second line');
  assert.ok(html.includes('Last 30 days · All branches'), 'the scope caption names period and branch');
});

test('v892 snapshot: a comparison is one line per metric, computed only from two server totals', () => {
  const html = plain(BI.snapshot(model()));
  assert.ok(html.includes('↑ 12% vs previous 30 days'), `revenue comparison, got: ${html}`);
  assert.ok(html.includes('↑ 13% vs previous 30 days'), 'customers comparison');
  assert.ok(html.includes('↑ 50% vs previous 30 days'), 'new customers comparison');
  assert.ok(!html.includes('No earlier period to compare yet'), 'no apology while a comparison exists');
});

test('v892 snapshot: with no earlier window the page apologises ONCE, not four times', () => {
  const html = plain(BI.snapshot(model({ truthPrev: null, lifecyclePrev: null })));
  assert.equal((html.match(/No earlier period to compare yet/g) || []).length, 1);
  assert.ok(!html.includes('vs previous'), 'no comparison line survives without an earlier window');
});

test('v892 snapshot: one metric without a comparison loses only its own line', () => {
  const html = plain(BI.snapshot(model({ truthPrev: null })));
  assert.ok(!html.includes('No earlier period to compare yet'), 'the whole-row apology is for the whole row');
  assert.equal((html.match(/vs previous 30 days/g) || []).length, 2, 'the other two metrics keep theirs');
});

test('v892 snapshot: an unknown figure is a dash, never a zero', () => {
  const html = plain(BI.snapshot(model({ truth: { status: 'insufficient' }, cashGap: null, lifecycle: null })));
  assert.ok(html.includes('—'), 'absence renders as a dash');
  assert.ok(!/\bSGD 0\.00\b/.test(html), 'nothing is invented as zero money');
});

/* ==================================================================================================
   2. The selector — priority, exclusion, de-duplication, and never padding to three.
   ================================================================================================== */
test('v892 selector: money first, then the customer at risk, then the server\'s ranked advice', () => {
  const cards = BI.select(model());
  assert.equal(cards.length, 3, 'at most three, and here there are three real ones');
  /* Joined, not deepEqual: these objects are built inside the vm realm, so an Array from there
     is not reference-equal to an Array from here even when it holds the same strings. */
  assert.equal(cards.map((card) => card.topic).join(' → '), 'cash → bringback → packages',
    'the ranked leakage item takes the third slot and de-duplicates the derived packages card');
  assert.equal(cards[0].type, 'needs_attention');
  assert.ok(spaced(cards[0].finding).includes('SGD 2,445.00'), 'the outstanding total leads the card');
  assert.equal(cards[0].why, '8 sales are not recorded as fully paid.',
    'sales_unpaid + sales_partly_paid, combined for the owner and split in the evidence');
  assert.match(cards[0].evidence.fact, /6 with no payment recorded and 2 part paid/);
});

test('v892 selector: the customer-risk card uses the server\'s own rhythm and its own verdict', () => {
  const cards = BI.select(model());
  const risk = cards.find((card) => card.topic === 'bringback');
  assert.equal(risk.finding, 'Siti Rahman usually visits every 21 days. Last seen 62 days ago.');
  assert.equal(risk.cta.href, '#/grow/bringback', 'the CTA is a route that exists');
});

test('v892 selector: an executable action outranks advisory advice, and is never manufactured', () => {
  const allowed = BI.select(model({
    cashGap: null, attention: null,
    action: { allowed: true, title: 'Invite 9 quiet regulars back', finding: 'Nine regulars are past their usual gap.', costMinor: 0 }
  }));
  assert.equal(allowed[0].topic, 'action');
  assert.equal(allowed[0].type, 'opportunity');
  assert.equal(allowed[0].finding, 'Invite 9 quiet regulars back');
  const withheld = BI.select(model({
    cashGap: null, attention: null,
    action: { allowed: false, title: 'Invite 9 quiet regulars back', finding: '', costMinor: null }
  }));
  assert.ok(!withheld.some((card) => card.topic === 'action'), 'a withheld action produces no card');
});

test('v892 selector: a coverage defect never takes one of the three slots', () => {
  const cards = BI.select(model({ cashGap: null, attention: null, packages: [] }));
  assert.ok(!cards.some((card) => card.finding.includes('sorted into categories')),
    'the foundation candidate is health, not one of the three things to know');
  assert.ok(cards.some((card) => card.topic === 'packages' || card.topic === 'services'),
    'the promoted, non-foundation candidates are what is left');
});

test('v892 selector: a card\'s type is read from the server\'s own buckets, not judged here', () => {
  const failure = { ...LEAKAGE_ITEM, id: 'no_discount_reminder', domain: 'discount_dependency' };
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: {
      ...OPPORTUNITIES, ranked: [failure, LEAKAGE_ITEM, STRENGTH_ITEM],
      report_sections: { strengths: ['strength:category:facial'], failures: ['no_discount_reminder'], leakage: ['package_leakage:plan_small'] }
    }
  }));
  const byTopic = Object.fromEntries(cards.map((card) => [card.topic, card.type]));
  assert.equal(byTopic.discounts, 'needs_attention', 'the failures bucket is something to fix');
  assert.equal(byTopic.packages, 'opportunity', 'leakage is money already paid for, not an alarm');
  assert.equal(byTopic.services, 'doing_well', 'the strengths bucket is something going well');
});

test('v892 selector: a strength reads as a strength, never as a task', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [FOUNDATION_ITEM, STRENGTH_ITEM] }
  }));
  const strength = cards.find((card) => card.type === 'doing_well');
  assert.ok(strength, 'the strength is surfaced');
  assert.equal(strength.action, '', 'a strength carries no instruction');
  assert.ok(!/protect|keep doing|nothing to change/i.test(`${strength.finding} ${strength.why}`));
});

test('v892 selector: one card per underlying insight — a ranked lapse and the attention row do not both take a slot', () => {
  const lapsed = { ...LEAKAGE_ITEM, id: 'lapsed_regulars', domain: 'cadence', pattern: 'Nine regulars are past their usual gap.' };
  const cards = BI.select(model({
    cashGap: null,
    opportunities: { ...OPPORTUNITIES, ranked: [lapsed], report_sections: { strengths: [], leakage: [] } }
  }));
  assert.equal(cards.filter((card) => card.topic === 'bringback').length, 1, 'one bring-back card only');
});

test('v892 selector: fewer than three real findings are never padded', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [], rhythm: null,
    opportunities: { ...OPPORTUNITIES, ranked: [FOUNDATION_ITEM], report_sections: {} }
  }));
  assert.equal(cards.length, 0, 'nothing real left once the coverage defect is excluded');
  assert.match(plain(BI.insights(cards)), /No reliable recommendation yet/);
});

test('v892 selector: with nothing to say but a reason to say it, Peekaa says it is still learning', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [], rhythm: null,
    opportunities: { ...OPPORTUNITIES, ranked: [], report_sections: {} },
    funnelConversion: { ...FUNNEL_CONVERSION, stage_1_to_2: { numerator: 1, denominator: 2, pct: null } }
  }));
  assert.equal(cards.length, 1);
  assert.equal(cards[0].type, 'still_learning');
  assert.match(cards[0].finding, /needs more customer history/);
});

test('v892 selector: a weekday strength names the day and its measured facts, and offers a look, not a chore', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [], report_sections: {} }
  }));
  const weekday = cards.find((card) => card.topic === 'weekday');
  assert.equal(weekday.type, 'doing_well');
  assert.equal(weekday.finding, 'Tuesday performs best');
  assert.ok(weekday.why.includes('5 visits'));
  assert.ok(spaced(weekday.why).includes('SGD 1,169.00'));
  assert.equal(weekday.action, '');
});

/* ==================================================================================================
   3. Cards and evidence.
   ================================================================================================== */
test('v892 card: each card carries its type, its finding, and its evidence behind one disclosure', () => {
  const html = BI.card(BI.select(model())[0]);
  assert.match(html, /bi-card--needs-attention/);
  assert.match(plain(html), /Needs attention/);
  assert.match(html, /<details class="bi-evidence"><summary>Why am I seeing this\?<\/summary>/);
});

test('v892 evidence: the sample size is translated into a sentence an owner can read', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [LEAKAGE_ITEM], report_sections: { leakage: ['package_leakage:plan_small'] } }
  }));
  const evidence = plain(BI.evidence(cards[0]));
  assert.ok(evidence.includes('Based on 9 observations. Peekaa requires at least 5 before showing this finding.'),
    `confidence.n and confidence.floor become one sentence, got: ${evidence}`);
  assert.ok(evidence.includes('Peekaa drops this once the remaining sessions are booked.'),
    'reversal_condition is printed as when Peekaa would change its mind');
});

test('v892 card: a CTA is either a route that exists or a control that opens a section here', () => {
  const ROUTES = new Set(['#/customerintel', '#/clients', '#/servicemapping', '#/grow/bringback',
    '#/reports', '#/staffperf', '#/custpackages', '#/bookings']);
  const cards = [
    ...BI.select(model()),
    ...BI.select(model({ cashGap: null, attention: null, packages: [] }))
  ];
  for (const card of cards) {
    if (!card.cta) continue;
    if (card.cta.kind === 'route') {
      assert.ok(ROUTES.has(card.cta.href) || card.cta.href.startsWith('#/client/'),
        `${card.cta.href} must be a route the router knows`);
    } else {
      assert.equal(card.cta.kind, 'section');
      assert.ok(card.cta.section, 'a section CTA names the section it opens');
    }
  }
  const html = BI.card(BI.select(model())[0]);
  assert.ok(!/href="#[a-zA-Z]/.test(html), 'no bare in-page anchor: the hash router would treat it as a route');
  /* Owner acceptance: a prepaid-sessions finding is acted on in Packages, not read in the ranked
     evidence panel — whichever of the two cards about it took the slot. */
  const prepaid = cards.find((card) => card.topic === 'packages');
  assert.equal(prepaid.cta.kind, 'route');
  assert.equal(prepaid.cta.href, '#/custpackages');
  assert.equal(prepaid.cta.label, 'View packages');
  const derived = BI.select(model({
    cashGap: null, attention: null,
    opportunities: { ...OPPORTUNITIES, ranked: [], report_sections: {} }
  })).find((card) => card.topic === 'packages');
  assert.equal(derived.cta.href, '#/custpackages', 'the derived card names the same destination');
  assert.equal(derived.cta.label, 'View packages');
});

/* ==================================================================================================
   4. Pulse and health.
   ================================================================================================== */
test('v892 pulse: one line of counts, and a figure Peekaa does not have is left out', () => {
  const line = plain(BI.pulse(model()));
  assert.ok(line.includes('9 customers'));
  assert.ok(line.includes('3 new'));
  assert.ok(line.includes('1 due back'));
  assert.ok(line.includes('1 slipping away'));
  assert.ok(line.includes('6 unused sessions'));
  const thin = plain(BI.pulse(model({ lifecycle: null, attention: null, packages: [] })));
  assert.ok(!thin.includes('customers'), 'an unknown count is absent, not zero');
  assert.equal(BI.pulse(model({ lifecycle: null, attention: null, packages: [], customers: [] })), '');
});

test('v892 health: coverage is a status row with its own route, never an alarm', () => {
  const html = plain(BI.health(model()));
  assert.ok(html.includes('Top 3 customers = 87% of known revenue'), `concentration, got: ${html}`);
  /* Owner acceptance: below three earning customers the row states arithmetic, not concentration. */
  const one = plain(BI.health(model({ customers: [CUSTOMERS[0]], summary: { net_revenue_cents: 357030 } })));
  assert.ok(!one.includes('Customer concentration'), 'one earning customer is not a concentration');
  const two = plain(BI.health(model({ customers: CUSTOMERS.slice(0, 2) })));
  assert.ok(!two.includes('Customer concentration'), 'nor are two');
  const three = plain(BI.health(model({ customers: CUSTOMERS.slice(0, 3) })));
  assert.ok(three.includes('Top 3 customers'), 'three earning customers is');
  assert.ok(html.includes('56.8% of revenue is sorted into categories'), 'category coverage as percent');
  assert.ok(html.includes('Age known for 33%'), 'profile coverage from the demographic totals');
  assert.match(BI.health(model()), /href="#\/servicemapping"/);
  assert.ok(!/bps/.test(html), 'the reader\'s basis points never reach the owner');
  assert.equal((html.match(/56\.8%/g) || []).length, 1,
    'the server\'s own coverage sentence is not printed alongside the rows built from the same facts');
  const bare = plain(BI.health(model({ categoryMix: null, demographics: null })));
  assert.ok(bare.includes('sorted into categories'),
    'with neither row available the server\'s own sentence is what the owner gets');
});

/* ==================================================================================================
   5. The overnight strip.
   ================================================================================================== */
test('v892 overnight: one strip, two sentences, the rest behind Show more', () => {
  const lines = [
    { kind: 'plain', text: 'Last 7 days: SGD 1,240.00 from 14 visits.' },
    { kind: 'plain', text: 'Busiest day Tuesday, slowest Friday.' },
    { kind: 'warn', text: '2 regulars are overdue their usual visit (SGD 120.00 a month at stake).' },
    { kind: 'good', text: 'Suggested: invite them back.' }
  ];
  const strip = sandbox({ ownerBriefLinesV826: () => lines }).overnight({ as_of: '2026-09-14', data_status: 'ok', brief: { week: {} } });
  const shown = plain(strip);
  assert.ok(shown.includes('Last night’s brief'));
  assert.ok(shown.includes('Last 7 days: SGD 1,240.00 from 14 visits.'));
  assert.ok(shown.includes('overdue their usual visit'), 'the regulars sentence leads with the first one');
  assert.match(strip, /<details class="bi-overnight-more"><summary>Show more<\/summary>/);
  assert.ok(shown.includes('Busiest day Tuesday'), 'the rest is still there, just folded');
  assert.equal(sandbox({ ownerBriefLinesV826: () => [] }).overnight({ data_status: 'not_computed', brief: null }), '');
});

/* ==================================================================================================
   6. Explore.
   ================================================================================================== */
test('v892 explore: a native, keyboard-usable accordion that drops a section with nothing in it', () => {
  const html = BI.explore([
    { key: 'customers', title: 'Customers', body: '<section id="a">rows</section>' },
    { key: 'empty', title: 'Nothing', body: '' },
    { key: 'money', title: 'Revenue & payments', hint: 'what was paid', body: '<section id="b">rows</section>' }
  ]);
  assert.equal((html.match(/<details class="bi-explore-group"/g) || []).length, 2, 'the empty group is dropped');
  assert.ok(!html.includes(' open>'), 'every group starts closed, so the page opens short');
  assert.match(html, /data-bi-section-v892="money"/);
  assert.ok(html.includes('<section id="a">rows</section>'), 'the existing renderers are carried verbatim');
  assert.equal(BI.explore([]), '');
});

/* ==================================================================================================
   7. The owner's language — the standing rule for this surface.
   ================================================================================================== */
test('v892: the primary surface speaks no machine, names no generator, and never prints a hole as a number', () => {
  const view = model();
  const cards = BI.select(view);
  const primary = [
    BI.snapshot(view), BI.insights(cards), BI.pulse(view), BI.health(view),
    sandbox({ ownerBriefLinesV826: () => [{ kind: 'warn', text: '2 regulars are overdue their usual visit.' }] })
      .overnight({ data_status: 'ok', brief: { week: {} } })
  ].join('\n');
  for (const banned of ['DIRECT_FACT', 'ASSOCIATION', 'sale_occurred_at', 'data_as_of', 'bps',
    'Unquantified', 'strength:category:', 'daypart_shift', 'lapsed_regulars', 'in_app',
    'rota_and_promotions', 'cents', 'null', 'undefined', 'NaN', 'examined', 'promoted',
    'WhatsApp', 'identified']) {
    assert.ok(!primary.includes(banned), `the primary surface must not say "${banned}"`);
  }
  assert.ok(!/\bwhatsapp\b/i.test(primary), 'the standing analytics ruling, in any casing');
});

test('v892: every empty and refused state renders without throwing and without a false zero', () => {
  const states = [
    {}, { truth: null, lifecycle: null, cashGap: null, attention: null, packages: [], customers: [], summary: null },
    { customers: [CUSTOMERS[0]], packages: [] },
    { cashGap: { totals: {} } },
    { attention: { rows: [], summary: {} } },
    { opportunities: null }, { opportunities: { ranked: [] } },
    { demographics: null }, { categoryMix: null }, { contactability: null }, { rhythm: null },
    { scope: { branchId: 'b1', branchCode: 'TMP', branchName: 'Tampines' } },
    { scope: { branchId: 'b1', branchCode: null, branchName: null } }
  ];
  for (const overrides of states) {
    const view = model(overrides);
    const html = [BI.snapshot(view), BI.insights(BI.select(view)), BI.pulse(view), BI.health(view)].join('\n');
    assert.ok(!/NaN|undefined/.test(html), `no machine hole for ${JSON.stringify(overrides).slice(0, 60)}`);
    assert.ok(!/>\s*null\s*</.test(html), 'no null rendered as a value');
  }
  const branch = plain(BI.snapshot(model({ scope: { branchId: 'b1', branchCode: 'TMP', branchName: 'Tampines' } })));
  assert.ok(branch.includes('Last 30 days · TMP · Tampines'), `a selected branch is named, got: ${branch}`);
});
