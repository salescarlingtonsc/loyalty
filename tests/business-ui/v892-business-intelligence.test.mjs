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
    __exports.explain=biExplainHtmlV892;
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
  pattern: 'Facials bring in 141000 cents, more revenue per customer than anything else you sell.',
  action: { who: 'nobody', what: '', when: '', channel: '' },
  impact: { cents: null }, confidence: { n: 12, floor: 5, status: 'ok' },
  evidence: {
    source_rpc: 'public.get_ci_category_mix_v1',
    refs: { node_key: 'facial', label: 'Facial', revenue_cents: 141000, customer_count: 6 }
  },
  evidence_class: 'ASSOCIATION', limitation: 'It says nothing about why.'
};
/* nestly_v894 — the shape v744 actually emits for the third card the owner reviewed: an
   analyst's `pattern` in cents, and alongside it every structured field the owner wording is
   built from (evidence.refs.top_share_bps / top_category, and the `concentration` block). */
const CONCENTRATION_ITEM = {
  id: 'category_concentration', rank: 4, rank_class: 'unquantified', domain: 'category_mix',
  pattern: '141000 cents of 168000 cents of classified revenue — 83.9% — comes from a single '
    + 'category (Facial), bought by 6 customers. Its top customer alone accounts for 39.8% of the category.',
  action: { who: 'the owner', what: 'Treat Facial as a single point of failure.' },
  impact: { cents: null }, confidence: { n: 6, floor: 5, status: 'ok' },
  concentration: { top1_share_bps: 3980, mean_excl_top1: 16000, skew_note: 'one customer carries it' },
  evidence: {
    source_rpc: 'public.get_ci_category_mix_v1',
    refs: {
      top_category: { node_key: 'facial', label: 'Facial', revenue_cents: 141000, customer_count: 6 },
      classified_revenue_cents: 168000, top_share_bps: 8393, coverage: { classified_pct_bps: 5680 }
    }
  },
  evidence_class: 'DIRECT_FACT',
  limitation: 'A concentrated mix is not automatically a fault.',
  reversal_condition: 'Reconsider if the share falls below the bar.'
};
/* An attention row whose identity was erased under PDPA: the placeholder erase_client_v290
   writes, verbatim. */
const ATTENTION_ERASED = {
  rows: [
    { client_id: 'c9', full_name: 'Erased customer', phone: null, status: 'slipping', last_visit_days: 48, cadence_days: 19.2 }
  ],
  summary: { due: 0, overdue: 0, slipping: 1, considered: 9, monthly_at_risk_cents: 145700 }
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
  /* nestly_v894: the Customers tile no longer repeats new_customers — the very next tile IS
     New customers, and saying it twice made the row read as five figures, not four. */
  assert.ok(!/\d+ new\b/.test(html), `no "N new" secondary line on the Customers tile, got: ${html}`);
  assert.ok(html.includes('New customers 3'), 'the New customers tile still carries it');
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
  assert.equal(cards[0].action, 'Review the open sales and record any payments already received.');
  assert.equal(cards[0].cta.label, 'Review payments');
  assert.equal(cards[0].cta.section, 'money', 'the same destination the old label pointed at');
  assert.match(cards[0].evidence.fact, /6 with no payment recorded and 2 part paid/);
});

test('v892 selector: the customer-risk card uses the server\'s own rhythm and its own verdict', () => {
  const cards = BI.select(model());
  const risk = cards.find((card) => card.topic === 'bringback');
  assert.equal(risk.finding, 'Siti Rahman usually visits every 21 days. Last seen 62 days ago.');
  assert.equal(risk.cta.href, '#/grow/bringback', 'the CTA is a route that exists');
  assert.equal(risk.type, 'customer_risk', 'a slipping regular is customer risk, not a red alarm');
  assert.equal(risk.action, '', 'no "call or message them": lawful contact is not this page to assume');
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

test('v894 selector: the owner\'s six card types, mapped from the server\'s own classes', () => {
  const failure = { ...LEAKAGE_ITEM, id: 'no_discount_reminder', domain: 'discount_dependency',
    evidence: { refs: { reminder_only_candidates_n: 4 } } };
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: {
      ...OPPORTUNITIES, ranked: [failure, LEAKAGE_ITEM, STRENGTH_ITEM],
      report_sections: { strengths: ['strength:category:facial'], failures: ['no_discount_reminder'], leakage: ['package_leakage:plan_small'] }
    }
  }));
  const byTopic = Object.fromEntries(cards.map((card) => [card.topic, card.type]));
  assert.equal(byTopic.discounts, 'opportunity', 'promoted advisory that is not exposure-shaped');
  assert.equal(byTopic.packages, 'opportunity', 'leakage is money already paid for, not an alarm');
  assert.equal(byTopic.services, 'doing_well', 'the strengths bucket is something going well');
  /* Money not collected is the only 🔴 on this surface; an exposure is 🟠 Business risk; a
     customer about to be lost is 🟠 Customer risk. */
  assert.equal(BI.select(model())[0].type, 'needs_attention', 'cash outstanding');
  const exposure = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [CONCENTRATION_ITEM], report_sections: {} }
  }));
  assert.equal(exposure[0].type, 'business_risk', 'category concentration is an exposure');
  const atRisk = BI.select(model({ cashGap: null }));
  assert.equal(atRisk.find((card) => card.topic === 'bringback').type, 'customer_risk');
  const kinds = BI.wording.types;
  assert.equal(Object.keys(kinds).join(' '),
    'needs_attention customer_risk business_risk opportunity doing_well still_learning');
  assert.equal(kinds.customer_risk.label, 'Customer risk');
  assert.equal(kinds.business_risk.label, 'Business risk');
  assert.equal(kinds.opportunity.mark, '\u{1F7E1}', 'Opportunity is warm yellow, not the risk orange');
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
test('v892 card: each card carries its type, its finding, and ONE control that opens the explanation', () => {
  const html = BI.card(BI.select(model())[0], 0);
  assert.match(html, /bi-card--needs-attention/);
  assert.match(plain(html), /Needs attention/);
  /* nestly_v901: the evidence is no longer inline; the card's only control opens the pop-up. */
  assert.match(html, /<button type="button" class="btn ghost sm bi-cta" data-bi-explain-v892="0">Why am I seeing this\? →<\/button>/);
  assert.ok(!html.includes('bi-evidence'), 'no inline evidence on the card');
  assert.ok(!html.includes('data-bi-open-v892'), 'no CTA on the card: it lives in the pop-up');
});

test('v901 explain pop-up: the numbers, then what to do next, then the CTA — from the card alone', () => {
  const card = BI.select(model())[0];
  const html = BI.explain(card);
  const text = plain(html);
  assert.match(html, /bi-explain bi-card--needs-attention/, 'the pop-up carries the card tone');
  assert.ok(text.includes('Where these numbers come from'), `numbers heading, got: ${text}`);
  assert.ok(text.includes('6 with no payment recorded and 2 part paid'), 'the evidence rows are inside the pop-up');
  assert.ok(text.includes('What to do next'), 'next-step heading');
  assert.ok(text.includes('Review the open sales and record any payments already received.'), 'the action sentence moved in');
  assert.match(html, /<button type="button" class="btn bi-explain-cta" data-bi-explain-cta="1">Review payments →<\/button>/);
  assert.ok(!/href="#/.test(html), 'the CTA is a button, so the dialog can close before navigating');
  const hidden = BI.explain(card, { showCta: false });
  assert.ok(!hidden.includes('data-bi-explain-cta'), 'a CTA with nowhere to go is left out, not left dead');
  assert.ok(plain(hidden).includes('What to do next'), 'the action sentence still stands on its own');
});

test('v892 evidence: the sample size is translated into a sentence an owner can read', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [LEAKAGE_ITEM], report_sections: { leakage: ['package_leakage:plan_small'] } }
  }));
  const evidence = plain(BI.evidence(cards[0]));
  assert.ok(evidence.includes('Based on 9 observations. Peekaa needs at least 5 before showing this finding.'),
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
  /* nestly_v894: exactly ONE esc() on a title, at render time. A title pre-escaped by its caller
     was escaped twice and reached the owner as a literal "&amp;". */
  assert.ok(html.includes('Revenue &amp; payments'), 'the ampersand is escaped once');
  assert.ok(!html.includes('&amp;amp;'), 'and never twice');
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

/* ==================================================================================================
   8. nestly_v894 — the owner-facing polish pass.

   The rule this section pins: the primary surface is written for the owner. The server's
   analytical `pattern` prose — cents, basis points, generator vocabulary — never reaches it,
   whatever the payload says; an erased identity is described rather than named; and a finding
   with no approved owner wording says where to read it instead of printing the analysis.
   ================================================================================================== */
const CONCENTRATION_ONLY = {
  ...OPPORTUNITIES, ranked: [CONCENTRATION_ITEM], report_sections: { strengths: [], failures: [] }
};

test('v894 card: category concentration is worded from its structured evidence, never from the prose', () => {
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [], opportunities: CONCENTRATION_ONLY
  }));
  const card = cards.find((entry) => entry.topic === 'concentration');
  assert.ok(card, 'the concentration finding takes a slot of its own');
  /* 8393 bps → 84%, the one conversion this surface performs. Nothing is hardcoded: the label,
     the share, the buyer count and the top-customer share all come out of the payload. */
  assert.equal(card.finding, 'Facial makes up 84% of your categorised revenue');
  assert.equal(card.why,
    '6 customers bought Facial, and your biggest Facial customer contributes about 40% of that category.');
  assert.equal(card.action, 'Your revenue is heavily concentrated in one service.');
  assert.equal(card.cta.kind, 'section');
  assert.equal(card.cta.section, 'services');
  assert.equal(card.cta.label, 'View services');
  const html = BI.insights(cards);
  assert.ok(!/cents/i.test(html), `the pattern's cents never reach the owner, got: ${plain(html)}`);
  assert.ok(!/83\.9|168000|141000/.test(html), 'nor its raw figures');
  assert.match(html, /bi-card--business-risk/);
});

test('v894 card: a generator with no approved owner wording prints no server prose at all', () => {
  const unknown = {
    id: 'some_future_generator', rank: 1, rank_class: 'quantified', domain: 'mystery',
    pattern: 'Segment X converts at 1420 bps against a 900 bps baseline, worth 41000 cents.',
    action: { what: 'Do the analyst thing.' }, impact: { cents: 41000 },
    confidence: { n: 11, floor: 5 }, evidence_class: 'ASSOCIATION'
  };
  const cards = BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [unknown], report_sections: {} }
  }));
  const card = cards.find((entry) => entry.finding === 'View this insight in detailed analysis');
  assert.ok(card, 'the untemplated finding falls back to a pointer, not to the prose');
  assert.equal(card.cta.section, 'evidence', 'and the pointer opens Evidence & methodology');
  const html = BI.insights(cards);
  assert.ok(!html.includes('Segment X'), 'the analyst sentence is not on the primary screen');
  for (const banned of ['cents', 'bps', 'ASSOCIATION']) {
    assert.ok(!html.includes(banned), `the primary surface must not say "${banned}"`);
  }
});

test('v894 ⚖️: an erased identity is described, never named, and never asked to be contacted', () => {
  const cards = BI.select(model({ cashGap: null, attention: ATTENTION_ERASED }));
  const card = cards.find((entry) => entry.topic === 'bringback');
  assert.equal(card.finding, 'A regular customer is slipping away');
  assert.equal(card.why, 'Usually visits every 19 days · last seen 48 days ago.');
  assert.ok(spaced(card.why2).includes('SGD 1,457.00'), `the money uses the grouped formatter, got: ${card.why2}`);
  assert.match(card.why2, /of regular spend may be at risk\.$/);
  assert.equal(card.action, '', 'no instruction to contact anyone');
  assert.equal(card.cta.label, 'Open bring-back list');
  const html = BI.insights(cards);
  assert.ok(!/Erased/i.test(html), 'the deletion-state placeholder is not a heading');
  for (const card2 of cards) {
    assert.ok(!/^(erased|deleted|anonymous|withheld|customer\b)/i.test(card2.finding),
      `no card heading starts with a deletion-state word, got: ${card2.finding}`);
  }
  /* An overdue erased row says overdue; the rhythm still comes from the server's own fields. */
  const overdue = BI.select(model({
    cashGap: null,
    attention: { ...ATTENTION_ERASED, rows: [{ ...ATTENTION_ERASED.rows[0], status: 'overdue' }] }
  })).find((entry) => entry.topic === 'bringback');
  assert.equal(overdue.finding, 'A regular customer is overdue');
  /* A name that IS legitimately visible keeps the existing form. */
  assert.equal(BI.select(model({ cashGap: null })).find((entry) => entry.topic === 'bringback').finding,
    'Siti Rahman usually visits every 21 days. Last seen 62 days ago.');
});

test('v894 evidence: the evidence class is translated, and the sample floor reads as a sentence', () => {
  const direct = plain(BI.evidence(BI.select(model({
    cashGap: null, attention: null, packages: [], opportunities: CONCENTRATION_ONLY
  }))[0]));
  assert.ok(direct.includes('Based directly on your recorded business data.'), `DIRECT_FACT, got: ${direct}`);
  assert.ok(!direct.includes('DIRECT_FACT'), 'and never the token');
  const association = plain(BI.evidence(BI.select(model({
    cashGap: null, attention: null, packages: [],
    opportunities: { ...OPPORTUNITIES, ranked: [STRENGTH_ITEM], report_sections: { strengths: ['strength:category:facial'] } }
  }))[0]));
  assert.ok(association.includes('Based on a pattern in your data, not a proven cause.'));
  assert.ok(!association.includes('ASSOCIATION'));
});

test('v894 pulse: exactly two chips carry emphasis', () => {
  const html = BI.pulse(model());
  assert.match(html, /<span class="bi-chip is-due">1 due back<\/span>/);
  assert.match(html, /<span class="bi-chip is-slipping">1 slipping away<\/span>/);
  assert.match(html, /<span class="bi-chip">9 customers<\/span>/);
  assert.match(html, /<span class="bi-chip">1 overdue<\/span>/, 'overdue is not one of the two');
  assert.equal((html.match(/bi-chip is-/g) || []).length, 2, 'and nothing else is toned');
});

test('v894 health: "Who you may contact" is a consent fact, not a health row', () => {
  const html = plain(BI.health(model()));
  assert.ok(!html.includes('Who you may contact'), 'it renders under Explore → Acquisition instead');
  assert.ok(!html.includes('by text message'), 'and none of its figures are duplicated here');
  /* Everything health keeps is still here. */
  assert.ok(html.includes('Top 3 customers'), 'concentration stays, with its ≥3 earning rule');
  assert.ok(html.includes('sorted into categories'), 'category coverage stays');
  assert.match(BI.health(model()), /Map services/, 'with its own route');
  assert.ok(html.includes('Age known for 33%'), 'profile completeness stays');
});

test('v894 overnight: the strip names the window it describes', () => {
  const strip = sandbox({
    ownerBriefLinesV826: () => [
      { kind: 'plain', text: 'Last 7 days: SGD 1,240.00 from 14 visits.' },
      { kind: 'warn', text: '2 regulars are overdue their usual visit.' },
      { kind: 'plain', text: 'Most redeemed reward: Free scalp massage.' }
    ]
  }).overnight({ data_status: 'ok', brief: { week: {} } });
  assert.ok(plain(strip).includes('Last night’s brief · Last 7 days'));
  assert.match(strip, /<details class="bi-overnight-more"><summary>Show more<\/summary>/);
});

test('v894: the banned-token scan, with a payload that carries every one of them', () => {
  const loaded = model({
    attention: ATTENTION_ERASED,
    opportunities: {
      ...OPPORTUNITIES,
      ranked: [FOUNDATION_ITEM, CONCENTRATION_ITEM, LEAKAGE_ITEM, STRENGTH_ITEM],
      report_sections: { strengths: ['strength:category:facial'], failures: [], leakage: ['package_leakage:plan_small'] }
    }
  });
  const primary = [
    BI.snapshot(loaded), BI.insights(BI.select(loaded)), BI.pulse(loaded), BI.health(loaded),
    sandbox({ ownerBriefLinesV826: () => [{ kind: 'plain', text: 'Last 7 days: SGD 1,240.00.' }] })
      .overnight({ data_status: 'ok', brief: { week: {} } })
  ].join('\n');
  for (const banned of ['cents', 'bps', 'DIRECT_FACT', 'ASSOCIATION', 'sale_occurred_at', 'data_as_of',
    'Unquantified', 'unquantified', 'category_concentration', 'package_leakage', 'strength:',
    'coverage_defect', 'node_key', 'top_share', '&amp;amp;', 'undefined', 'NaN', 'Erased']) {
    assert.ok(!primary.includes(banned), `the primary surface must not say "${banned}"`);
  }
  assert.ok(!/>\s*null\s*</.test(primary), 'no null rendered as a value');
  assert.ok(!/\bnull\b/.test(plain(primary)), 'and none in the text either');
});

test('v894 explore: the section labels an owner reads, each escaped exactly once', () => {
  const html = BI.explore([
    { key: 'money', title: 'Revenue & payments', hint: 'What was recorded, collected, and still owed', body: '<i>x</i>' },
    { key: 'behaviour', title: 'Weekday & time-of-day behaviour', hint: 'When customers come in', body: '<i>x</i>' },
    { key: 'evidence', title: 'Evidence & methodology', hint: 'Why Peekaa reached its findings', body: '<i>x</i>' }
  ]);
  /* What the BROWSER shows: tags stripped, then the one entity decoded. A correctly escaped
     "&amp;" in the markup renders as "&"; the double escape rendered as the literal "&amp;". */
  const text = plain(html).split('&amp;').join('&');
  for (const label of ['Revenue & payments', 'Weekday & time-of-day behaviour', 'Evidence & methodology']) {
    assert.ok(text.includes(label), `"${label}" reads with a literal ampersand, got: ${text}`);
  }
  assert.ok(!text.includes('&amp;'), 'no escaped entity survives into the rendered text');
  assert.ok(!html.includes('&amp;amp;'), 'and the markup is escaped once, not twice');
  assert.equal((html.match(/&amp;/g) || []).length, 3, 'one escape per ampersand, in the markup');
});

/* The page's own Explore wiring: the labels and the one place contactability renders. Source-level
   on purpose — this is the caller, not a function, and what must be pinned is that the titles are
   PLAIN TEXT (so the single esc() above is the only escape) and that the contactability panel is
   mounted exactly once, under Acquisition. */
test('v894 page: Explore titles are plain text, and contactability renders once', () => {
  const start = app.indexOf('const biExplore=biExploreHtmlV892([');
  assert.ok(start > -1, 'the Explore wiring must exist');
  const wiring = app.slice(start, app.indexOf('body.innerHTML=`${biSnapshotHtmlV892', start));
  assert.ok(!wiring.includes('&amp;'), 'no title is pre-escaped in the data');
  for (const title of ["title:'Revenue & payments'", "title:'Weekday & time-of-day behaviour'",
    "title:'Evidence & methodology'"]) {
    assert.ok(wiring.includes(title), `${title} is carried as plain text`);
  }
  assert.equal((wiring.match(/contactabilityMarkupV650\(\)/g) || []).length, 1,
    'the contactability panel is mounted exactly once');
  assert.ok(/key:'acquisition'[^}]*contactabilityMarkupV650/s.test(wiring)
    || wiring.indexOf('contactabilityMarkupV650') > wiring.indexOf("key:'acquisition'"),
    'and it is the Acquisition group that mounts it');
});
